import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/word_timestamp.dart';
import '../utils/constants.dart';

class SonioxRealtimeService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 50;
  bool _intentionallyClosed = false;
  bool _isReconnecting = false;
  bool _isRotating = false;
  // Cancelable handle for the scheduled reconnect, so a deliberate (re)connect
  // (iOS resume, rotation, stop/restart) can cancel a stale pending reconnect
  // instead of letting it fire and open a duplicate socket.
  Timer? _reconnectTimer;
  // True while a _doConnect attempt is in flight — prevents two overlapping
  // connects (e.g. a scheduled reconnect racing ensureConnected) from opening
  // two channels and leaking one.
  bool _connecting = false;
  static final Random _rand = Random();

  // Auth credentials for proxy — set before calling connect()
  String? userId;
  String? authToken;

  // Private Soniox key mode — compile-time or server-side flag
  static const _isPrivateBuild = String.fromEnvironment('SONIOX_PRIVATE');
  bool isPrivateUser = false;
  bool get _usePrivate => _isPrivateBuild == 'true' || isPrivateUser;

  // Transcription token state
  String _pendingUtterance = '';
  String _provisionalText = '';

  // Translation token state
  String _pendingTranslation = '';
  String _provisionalTranslation = '';

  // Stored for reconnect
  String? _targetLanguageCode;
  List<String>? _twoWayLanguageCodes;

  // Language identification
  String? _lastDetectedLanguage;

  // ─── Two-way translation routing (Conversation mode) ───
  // Soniox `two_way` translation auto-detects which of the two languages the
  // speaker used: original tokens carry the spoken `language`, and translation
  // tokens carry `source_language` (the language they were translated FROM).
  // We surface the live value (for routing the in-progress draft) and the value
  // locked at each completion (read synchronously inside onTranscriptionCompleted
  // / onTranslationCompleted), so the caller can route every utterance to the
  // correct side by detected language instead of by which mic was pressed.
  String? currentSourceLanguage;
  String? lastCompletedSourceLanguage;
  String? currentTranslationSourceLanguage;
  String? lastCompletedTranslationSourceLanguage;

  // ─── Speaker diarization ───
  // With `enable_speaker_diarization`, Soniox labels every token with a
  // numeric speaker string ("1", "2", ...). Labels on non-final tokens can
  // flip before stabilizing, so speaker state is tracked from FINAL tokens
  // only. Numbering is per-WebSocket-session: rotation/reconnect restarts it,
  // so a label may not identify the same person across a rotation.
  int? currentSpeaker;

  /// Dominant speaker of the most recently completed utterance.
  /// Read this synchronously inside the onTranscriptionCompleted callback.
  int? lastCompletedSpeaker;

  /// True when the translation completion being delivered arrived AFTER its
  /// utterance's source endpoint (late flush) — it belongs to the LAST
  /// completed transcript line, not to the utterance completing now. A single
  /// utterance can produce several completions (Soniox translates sentence by
  /// sentence, so trailing sentences flush late); this flag lets the caller
  /// merge them into the right line instead of treating each as a new segment.
  /// Read this synchronously inside the onTranslationCompleted callback.
  bool lastTranslationWasLate = false;

  // Final-token counts per speaker for the in-progress utterance — an
  // utterance that mixes speakers is attributed to its dominant one.
  final Map<int, int> _pendingSpeakerCounts = {};

  // Word timestamps — per-utterance accumulation
  final List<WordTimestamp> _pendingWords = [];

  /// Word timestamps for the most recently completed utterance.
  /// Read this synchronously inside the onTranscriptionCompleted callback.
  List<WordTimestamp> lastCompletedWords = [];

  // Context — set by the caller to improve accuracy on rotations
  String? contextText;

  // Audio buffer during reconnection — capped at 30s of audio to avoid OOM
  static const _maxBufferBytes = 24000 * 2 * 30;
  final Queue<Uint8List> _audioBuffer = Queue<Uint8List>();
  int _audioBufferBytes = 0;

  // Session rotation — prevents translation model degradation in long sessions
  Timer? _rotationTimer;
  static const _rotationIntervalMinutes = 10;

  // Late translation flush — debounces late-arriving translation tokens that
  // come in AFTER the source endpoint has already fired. Without this, those
  // tokens would get stuck in _pendingTranslation and merge with the NEXT
  // utterance's translation, causing visual "adjacency" bugs in the draft.
  Timer? _lateTranslationTimer;
  static const _lateTranslationFlushMs = 800;

  // Finalize settle — press-and-hold callers (Quick/Conversation) stop on user
  // release and await finalizeAndWait(), which resolves once the provider has
  // gone quiet (no new tokens for _settleQuiet) or acknowledges with
  // `finished: true`. Translation lags the source, so this lets trailing
  // translation tokens land BEFORE disconnect() tears the socket down.
  Completer<void>? _settleCompleter;
  Timer? _settleQuietTimer;
  Duration _settleQuiet = const Duration(milliseconds: 500);

  // Callbacks
  Function(String draft)? onTranscriptionDraft;
  Function(String transcript)? onTranscriptionCompleted;
  Function(String draft)? onTranslationDraft;
  Function(String translation)? onTranslationCompleted;
  Function(String error)? onError;
  Function()? onConnected;
  Function(String language)? onLanguageDetected;
  Function(int speaker)? onSpeakerChanged;
  Function()? onUsageLimitReached;

  bool _forceTranslation = false;
  String? _languageHint;
  bool _enableSpeakerDiarization = false;

  // Endpoint tuning — defaults to the neutral global constants; the caller can
  // override per display mode (e.g. line-by-line uses fuller/later endpoints so
  // Soniox translates complete clauses instead of subjectless fragments).
  // Stored so rotation/reconnect rebuild the session with the same settings.
  int _maxEndpointDelayMs = AppConstants.endpointDelayMs;
  double _endpointSensitivity = AppConstants.endpointSensitivity;
  int _endpointLatencyAdjustmentLevel =
      AppConstants.endpointLatencyAdjustmentLevel;

  bool get isConnected => _channel != null && !_isReconnecting;

  /// True once the session has been intentionally torn down (usage-limit 4005
  /// or explicit disconnect). Lets a caller detect a session that died during
  /// its own awaited connect window.
  bool get isClosed => _intentionallyClosed;

  bool get _isTwoWay =>
      _twoWayLanguageCodes != null && _twoWayLanguageCodes!.length == 2;

  Future<void> connect({
    String? targetLanguageCode,
    List<String>? twoWayLanguageCodes,
    bool forceTranslation = false,
    String? languageHint,
    bool enableSpeakerDiarization = false,
    int? maxEndpointDelayMs,
    double? endpointSensitivity,
    int? endpointLatencyAdjustmentLevel,
  }) async {
    _intentionallyClosed = false;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _targetLanguageCode = targetLanguageCode;
    _twoWayLanguageCodes = twoWayLanguageCodes;
    _forceTranslation = forceTranslation;
    _languageHint = languageHint;
    _enableSpeakerDiarization = enableSpeakerDiarization;
    _maxEndpointDelayMs = maxEndpointDelayMs ?? AppConstants.endpointDelayMs;
    _endpointSensitivity =
        endpointSensitivity ?? AppConstants.endpointSensitivity;
    _endpointLatencyAdjustmentLevel = endpointLatencyAdjustmentLevel ??
        AppConstants.endpointLatencyAdjustmentLevel;
    _resetTokenState();
    _clearAudioBuffer();
    await _doConnect();
    // Callers may run connect() unawaited (optimistic recording start) and
    // disconnect() while the handshake is still in flight — that teardown
    // already stopped the rotation timer, so don't restart it on a session
    // that has been intentionally closed.
    if (!_intentionallyClosed) _startRotationTimer();
  }

  Future<void> _doConnect() async {
    // Every _doConnect opens a fresh Soniox session, and speaker numbering
    // restarts per session — that includes the plain reconnect and iOS-resume
    // paths, which (unlike connect/rotation) skip _resetTokenState to keep the
    // interrupted utterance's text. Drop only the speaker state here so
    // old-session counts never merge into the new session's numbering space.
    // Guard against overlapping connect attempts (e.g. a scheduled reconnect
    // firing while an iOS-resume ensureConnected() is already reconnecting).
    // Without this, two channels could open and one would leak — holding a
    // scarce Soniox slot and later tearing down the healthy socket.
    if (_connecting) return;
    _connecting = true;
    try {
      // A deliberate (re)connect supersedes any pending scheduled reconnect.
      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      currentSpeaker = null;
      _pendingSpeakerCounts.clear();

      final WebSocketChannel channel;
      try {
        final wsPath = _usePrivate
            ? AppConstants.sonioxProxyUrl
            : AppConstants.sonioxLimitedProxyUrl;
        final proxyUrl = Uri.parse(wsPath).replace(
          queryParameters: {
            if (userId != null) 'userId': userId!,
            if (authToken != null) 'token': authToken!,
            if (_usePrivate) 'private': '1',
          },
        );
        channel = IOWebSocketChannel.connect(
          proxyUrl,
          pingInterval: const Duration(seconds: 15),
        );
      } catch (e) {
        // Synchronous failure (e.g. malformed URI) — schedule a retry.
        _handleDisconnect('connect error: $e');
        return;
      }

      // IOWebSocketChannel.connect is LAZY: it returns before the handshake
      // completes and never throws synchronously on a failed connection — the
      // failure only surfaces via `ready` (or the stream). Await it so we never
      // declare the connection live, reset the retry counter, flush buffered
      // audio, or fire onConnected for a socket that never actually opened.
      try {
        // Bound the handshake so a black-hole connection (associated to a
        // network but silently dropping packets) fails fast into the backoff
        // reconnect instead of pinning _connecting until the OS TCP timeout.
        await channel.ready.timeout(const Duration(seconds: 10));
      } catch (e) {
        try {
          await channel.sink.close();
        } catch (_) {}
        _handleDisconnect('handshake failed: $e');
        return;
      }

      // Torn down (usage-limit 4005 or disconnect) while awaiting the
      // handshake — abandon this now-orphan channel.
      if (_intentionallyClosed) {
        try {
          await channel.sink.close();
        } catch (_) {}
        return;
      }

      // Adopt the new channel, closing any prior one so a race can never leak a
      // live socket.
      _subscription?.cancel();
      _subscription = null;
      final previous = _channel;
      _channel = channel;
      if (previous != null && previous != channel) {
        try {
          await previous.sink.close();
        } catch (_) {}
      }

      // Listen before sending config so no early server response is missed.
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (error) {
          _handleDisconnect('stream error: $error');
        },
        onDone: () {
          _handleDisconnect('stream closed');
        },
        cancelOnError: true,
      );

      try {
        channel.sink.add(jsonEncode(_buildConfig()));
      } catch (e) {
        _handleDisconnect('config send failed: $e');
        return;
      }

      // The connection is proven live — only NOW is it safe to reset retry
      // state, flush buffered audio, and notify the caller.
      _reconnectAttempts = 0;
      _isReconnecting = false;
      _isRotating = false;
      _flushAudioBuffer();
      onConnected?.call();
    } finally {
      _connecting = false;
    }
  }

  Map<String, dynamic> _buildConfig() {
    final config = <String, dynamic>{
      'model': AppConstants.sonioxModel,
      'audio_format': AppConstants.audioFormat,
      'sample_rate': AppConstants.sampleRate,
      'num_channels': AppConstants.numChannels,
      'enable_endpoint_detection': true,
      'max_endpoint_delay_ms': _maxEndpointDelayMs,
      // v5 semantic-endpointing tuning (ignored by pre-v5 models).
      'endpoint_sensitivity': _endpointSensitivity,
      'endpoint_latency_adjustment_level': _endpointLatencyAdjustmentLevel,
      'enable_language_identification': true,
      if (_enableSpeakerDiarization) 'enable_speaker_diarization': true,
    };

    // Language hints
    if (_twoWayLanguageCodes != null && _twoWayLanguageCodes!.length == 2) {
      config['language_hints'] = _twoWayLanguageCodes;
    } else {
      final hint = _languageHint ?? AppConstants.transcriptionLanguage;
      if (hint.isNotEmpty) {
        config['language_hints'] = [hint];
      }
    }

    // Translation config
    if (_twoWayLanguageCodes != null && _twoWayLanguageCodes!.length == 2) {
      config['translation'] = {
        'type': 'two_way',
        'language_a': _twoWayLanguageCodes![0],
        'language_b': _twoWayLanguageCodes![1],
      };
    } else if (_targetLanguageCode != null &&
        (_forceTranslation ||
            _targetLanguageCode != AppConstants.transcriptionLanguage)) {
      config['translation'] = {
        'type': 'one_way',
        'target_language': _targetLanguageCode,
      };
    }

    // Context — helps model with domain understanding and recurring terms
    final context = <String, dynamic>{
      'general': [
        {
          'key': 'domain',
          'value': 'Real-time spoken conversation translation',
        },
      ],
    };
    if (contextText != null && contextText!.isNotEmpty) {
      context['text'] = contextText;
    }
    config['context'] = context;
    return config;
  }

  void _handleDisconnect(String reason) {
    if (_intentionallyClosed) return;

    // Proxy signals usage limit with WS close code 4005. Capture before
    // nulling _channel so we don't race with reconnect logic.
    final closeCode = _channel?.closeCode;

    _subscription?.cancel();
    _subscription = null;
    _channel = null;

    if (closeCode == 4005) {
      _intentionallyClosed = true;
      _stopRotationTimer();
      _clearAudioBuffer();
      onUsageLimitReached?.call();
      return;
    }

    if (!_isRotating) {
      _tryReconnect();
    }
    // If _isRotating is true, _rotateSession handles its own reconnection.
    // The fallback at the end of _rotateSession covers the case where
    // _doConnect fails synchronously during rotation.
  }

  // ─── Session rotation ───

  void _startRotationTimer() {
    _rotationTimer?.cancel();
    _rotationTimer = Timer.periodic(
      const Duration(minutes: _rotationIntervalMinutes),
      (_) => _rotateSession(),
    );
  }

  void _stopRotationTimer() {
    _rotationTimer?.cancel();
    _rotationTimer = null;
  }

  /// Transparently close and reopen the Soniox session to reset the
  /// translation model context. Audio is buffered during the brief gap.
  Future<void> _rotateSession() async {
    if (_intentionallyClosed || _isReconnecting || _isRotating) return;
    _isRotating = true;
    // A rotation supersedes any pending scheduled reconnect.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Finalize current session
    finalize();
    await Future.delayed(const Duration(milliseconds: 300));

    // Tear down current connection
    _subscription?.cancel();
    _subscription = null;

    // Flush any pending tokens to callbacks BEFORE resetting state
    _flushPendingTokens();

    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    _resetTokenState();
    _reconnectAttempts = 0;

    // Reconnect (audio buffered automatically during this gap)
    await _doConnect();

    // If _doConnect threw synchronously, _handleDisconnect skipped
    // reconnection (because _isRotating was true). Fall back to
    // normal reconnection so the service doesn't get stuck.
    if (_isRotating) {
      _isRotating = false;
      _tryReconnect();
    }
  }

  /// Flush accumulated pending tokens to callbacks without losing data.
  void _flushPendingTokens() {
    _lateTranslationTimer?.cancel();
    // The transcription flush below drops empty/looping text, so the
    // translation's pairing must follow what will ACTUALLY be emitted: with an
    // emittable pending transcript it pairs with that upcoming line
    // (isLate: false); with no pending transcript it belongs to the last
    // completed line (isLate: true); and when the transcript is discarded as
    // a repetition loop, its translation is discarded with it — emitting it
    // would orphan a translation line with no transcript to pair with.
    final utteranceText = (_pendingUtterance + _provisionalText).trim();
    final willEmitTranscript =
        utteranceText.isNotEmpty && !_hasRepetitionLoop(utteranceText);
    if (_pendingTranslation.isNotEmpty || _provisionalTranslation.isNotEmpty) {
      final text = (_pendingTranslation + _provisionalTranslation).trim();
      if (text.isNotEmpty &&
          !_hasRepetitionLoop(text) &&
          (willEmitTranscript || utteranceText.isEmpty)) {
        _emitTranslationCompleted(text, isLate: !willEmitTranscript);
      }
      _pendingTranslation = '';
      _provisionalTranslation = '';
    }
    if (_pendingUtterance.isNotEmpty || _provisionalText.isNotEmpty) {
      if (willEmitTranscript) {
        lastCompletedWords = List.from(_pendingWords);
        _emitTranscriptionCompleted(utteranceText);
      }
      _pendingUtterance = '';
      _provisionalText = '';
      _pendingWords.clear();
    }
  }

  // ─── Repetition detection ───

  /// Detect if text is a repetition loop (e.g., "Nguyên Duy" repeated 30x).
  /// Uses two heuristics:
  ///  1. Unique-word ratio: normal prose has 30%+ unique words; loops have < 15%
  ///  2. Single-word dominance: any word appearing >= 40% of the time
  /// Either condition triggers detection.
  bool _hasRepetitionLoop(String text) {
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.length < 12) return false;

    final uniqueWords = words.toSet();

    // Heuristic 1: very few unique words relative to total
    // "Duy Nguyên Duy Nguyên..." → 2 unique / 100 total = 2%
    if (uniqueWords.length / words.length < 0.15) return true;

    // Heuristic 2: any single word dominates >= 40%
    // Catches "Dương Dương Dương" mixed with occasional other words
    final freq = <String, int>{};
    for (final w in words) {
      freq[w] = (freq[w] ?? 0) + 1;
    }
    final maxFreq = freq.values.reduce((a, b) => a > b ? a : b);
    return maxFreq >= words.length * 0.4;
  }

  // ─── Completion emitters ───
  // All transcription/translation completions funnel through these so the
  // detected source language is locked alongside the text. Non-conversation
  // callers simply ignore the `lastCompleted*Language` fields.

  void _emitTranscriptionCompleted(String text) {
    lastCompletedSourceLanguage = currentSourceLanguage;
    lastCompletedSpeaker = _dominantPendingSpeaker();
    _pendingSpeakerCounts.clear();
    final cb = onTranscriptionCompleted;
    if (cb != null) cb(text);
  }

  /// The speaker with the most final tokens in the in-progress utterance,
  /// falling back to the last attributed speaker (an utterance whose tokens
  /// carried no speaker labels inherits the current one for continuity).
  int? _dominantPendingSpeaker() {
    int? dominant;
    var best = 0;
    _pendingSpeakerCounts.forEach((speaker, count) {
      if (count > best) {
        best = count;
        dominant = speaker;
      }
    });
    return dominant ?? currentSpeaker;
  }

  /// Soniox sends speaker labels as numeric strings ("1", "2", ...); accept
  /// ints defensively.
  static int? _parseSpeakerLabel(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  void _emitTranslationCompleted(String text, {bool isLate = false}) {
    lastTranslationWasLate = isLate;
    lastCompletedTranslationSourceLanguage = currentTranslationSourceLanguage;
    final cb = onTranslationCompleted;
    if (cb != null) cb(text);
  }

  // ─── Token processing ───

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

      if (data['error_code'] != null) {
        // Log the provider's raw error for diagnostics, but surface only a
        // generic message so vendor-identifying text never reaches the UI.
        final rawError = data['error_message'] as String? ?? 'unknown error';
        debugPrint('Transcription service error: $rawError');
        onError?.call('A transcription error occurred. Please try again.');
        return;
      }

      if (data['finished'] == true) {
        _completeSettle();
        return;
      }

      final tokens = data['tokens'] as List<dynamic>?;
      if (tokens == null || tokens.isEmpty) return;

      // A token arrived — if a finalize-settle wait is active, extend it so we
      // keep waiting while the provider is still streaming (e.g. trailing
      // translation tokens that arrive after the source finalized).
      _armSettleTimer();

      final sourceTokens = <Map<String, dynamic>>[];
      final translationTokens = <Map<String, dynamic>>[];

      for (final token in tokens) {
        final status = token['translation_status'] as String?;
        if (status == 'translation') {
          translationTokens.add(token as Map<String, dynamic>);
        } else {
          sourceTokens.add(token as Map<String, dynamic>);
        }
      }

      if (sourceTokens.isNotEmpty) {
        _processSourceTokens(sourceTokens);
      }
      if (translationTokens.isNotEmpty) {
        _processTranslationTokens(translationTokens);
      }
    } catch (e) {
      debugPrint('Failed to parse transcription message: $e');
      onError?.call('A transcription error occurred. Please try again.');
    }
  }

  /// Flushes any lingering translation buffer as a completion. Called when
  /// new source tokens arrive for the next utterance (pre-empting the late
  /// debounce timer) or when the debounce timer itself fires.
  void _flushLateTranslation() {
    _lateTranslationTimer?.cancel();
    if (_pendingTranslation.isEmpty && _provisionalTranslation.isEmpty) return;
    final text = (_pendingTranslation + _provisionalTranslation).trim();
    if (text.isNotEmpty && !_hasRepetitionLoop(text)) {
      _emitTranslationCompleted(text, isLate: true);
    }
    _pendingTranslation = '';
    _provisionalTranslation = '';
  }

  void _processSourceTokens(List<Map<String, dynamic>> tokens) {
    // Flush any late-arriving translation tokens from the PREVIOUS utterance
    // before we start accumulating source for the NEXT one. Without this,
    // translation tokens that arrived after the previous source endpoint
    // (because Soniox's translation lags the source) would stay in
    // _pendingTranslation and get concatenated onto the next utterance's
    // translation, producing a visually "stuck together" draft.
    if (_pendingUtterance.isEmpty &&
        _provisionalText.isEmpty &&
        (_pendingTranslation.isNotEmpty ||
            _provisionalTranslation.isNotEmpty)) {
      _flushLateTranslation();
    }

    final hadProvisional = _provisionalText.isNotEmpty;
    String newProvisionalText = '';
    String newFinalText = '';

    for (final token in tokens) {
      final text = token['text'] as String? ?? '';
      final isFinal = token['is_final'] as bool? ?? false;
      final language = token['language'] as String?;
      if (language != null) {
        // Track the spoken language of the current utterance for two-way
        // routing; also notify on change for the detected-language UI.
        currentSourceLanguage = language;
        if (language != _lastDetectedLanguage) {
          _lastDetectedLanguage = language;
          onLanguageDetected?.call(language);
        }
      }
      // Diarization: attribute by FINAL tokens only — non-final labels can
      // flip before stabilizing ("temporary speaker switches" per Soniox).
      if (isFinal) {
        final speaker = _parseSpeakerLabel(token['speaker']);
        if (speaker != null) {
          _pendingSpeakerCounts[speaker] =
              (_pendingSpeakerCounts[speaker] ?? 0) + 1;
          if (speaker != currentSpeaker) {
            currentSpeaker = speaker;
            onSpeakerChanged?.call(speaker);
          }
        }
      }
      if (text.startsWith('<') && text.endsWith('>')) continue;
      if (isFinal) {
        newFinalText += text;
        final startMs = token['start_ms'] as int?;
        if (startMs != null) {
          _pendingWords.add(WordTimestamp(text, startMs));
        }
      } else {
        newProvisionalText += text;
      }
    }

    _pendingUtterance += newFinalText;
    _provisionalText = newProvisionalText;

    // Safety cap on transcription buffer (same logic as translation)
    if (_pendingUtterance.length > 2000) {
      final text = _pendingUtterance.trim();
      if (text.isNotEmpty && !_hasRepetitionLoop(text)) {
        lastCompletedWords = List.from(_pendingWords);
        _emitTranscriptionCompleted(text);
      }
      _pendingUtterance = '';
      _provisionalText = '';
      _pendingWords.clear();
      _rotateSession();
      return;
    }

    onTranscriptionDraft?.call(_pendingUtterance + _provisionalText);

    if (hadProvisional &&
        _provisionalText.isEmpty &&
        _pendingUtterance.isNotEmpty) {
      // Flush translation FIRST (fills the correct slot)
      final fullTranslation =
          (_pendingTranslation + _provisionalTranslation).trim();

      if (fullTranslation.isNotEmpty && _hasRepetitionLoop(fullTranslation)) {
        // Garbage detected — discard and force-rotate
        _pendingTranslation = '';
        _provisionalTranslation = '';
        _pendingUtterance = '';
        _pendingWords.clear();
        onTranslationDraft?.call('');
        _rotateSession();
        return;
      }

      // Always signal translation completion at endpoint (even if empty)
      // so line-by-line slot alignment stays in sync.
      _emitTranslationCompleted(fullTranslation);
      _pendingTranslation = '';
      _provisionalTranslation = '';

      lastCompletedWords = List.from(_pendingWords);
      _pendingWords.clear();
      _emitTranscriptionCompleted(_pendingUtterance.trim());
      _pendingUtterance = '';
    }
  }

  void _processTranslationTokens(List<Map<String, dynamic>> tokens) {
    // Two-way: translation tokens name the language they were translated FROM.
    // When that flips while a previous speaker's translation is still buffered
    // (their trailing tokens lagged past the next speaker's turn), flush it
    // first — routed to the previous speaker via the still-current source
    // language — so two speakers' translations never merge into one bubble.
    if (_isTwoWay &&
        currentTranslationSourceLanguage != null &&
        (_pendingTranslation.isNotEmpty ||
            _provisionalTranslation.isNotEmpty)) {
      for (final token in tokens) {
        final s = token['source_language'] as String?;
        if (s == null) continue;
        if (s != currentTranslationSourceLanguage) _flushLateTranslation();
        break;
      }
    }

    String newProvisionalText = '';
    String newFinalText = '';

    for (final token in tokens) {
      final text = token['text'] as String? ?? '';
      final isFinal = token['is_final'] as bool? ?? false;
      // In two-way mode each translation token names the language it was
      // translated FROM — the authoritative signal for which side spoke it,
      // robust even if the other speaker has already begun the next turn.
      final srcLang = token['source_language'] as String?;
      if (srcLang != null) currentTranslationSourceLanguage = srcLang;
      if (text.startsWith('<') && text.endsWith('>')) continue;
      if (isFinal) {
        newFinalText += text;
      } else {
        newProvisionalText += text;
      }
    }

    _pendingTranslation += newFinalText;
    _provisionalTranslation = newProvisionalText;

    // ── Repetition guard ──
    if (_pendingTranslation.length > 200 &&
        _hasRepetitionLoop(_pendingTranslation)) {
      _pendingTranslation = '';
      _provisionalTranslation = '';
      onTranslationDraft?.call('');
      _rotateSession();
      return;
    }

    if (_pendingTranslation.length > 2000) {
      final text = _pendingTranslation.trim();
      if (text.isNotEmpty && !_hasRepetitionLoop(text)) {
        _emitTranslationCompleted(
          text,
          isLate: (_pendingUtterance + _provisionalText).trim().isEmpty,
        );
      }
      _pendingTranslation = '';
      _provisionalTranslation = '';
      _rotateSession();
      return;
    }

    onTranslationDraft?.call(_pendingTranslation + _provisionalTranslation);

    // Late-translation debounce: if these tokens arrived while we're between
    // utterances (source buffers empty because the last endpoint already
    // fired), they belong to the PREVIOUS utterance. Schedule a flush so
    // they get confirmed into history before the next utterance starts.
    // Cancelled/replaced if more translation tokens arrive, or pre-empted
    // by _processSourceTokens when new source tokens arrive.
    if (_pendingUtterance.isEmpty && _provisionalText.isEmpty) {
      _lateTranslationTimer?.cancel();
      _lateTranslationTimer = Timer(
        const Duration(milliseconds: _lateTranslationFlushMs),
        _flushLateTranslation,
      );
    }
  }

  // ─── Audio sending ───

  void sendAudio(Uint8List audioBytes) {
    if (_intentionallyClosed) return;

    if (_isReconnecting || _isRotating || _channel == null) {
      _audioBuffer.addLast(audioBytes);
      _audioBufferBytes += audioBytes.length;
      while (_audioBufferBytes > _maxBufferBytes && _audioBuffer.isNotEmpty) {
        final removed = _audioBuffer.removeFirst();
        _audioBufferBytes -= removed.length;
      }
      return;
    }

    try {
      _channel!.sink.add(audioBytes);
    } catch (_) {}
  }

  void _flushAudioBuffer() {
    if (_channel == null) return;
    while (_audioBuffer.isNotEmpty) {
      try {
        _channel!.sink.add(_audioBuffer.removeFirst());
      } catch (_) {
        break;
      }
    }
    _audioBufferBytes = 0;
  }

  void _clearAudioBuffer() {
    _audioBuffer.clear();
    _audioBufferBytes = 0;
  }

  void finalize() {
    if (_channel == null) return;
    try {
      _channel!.sink.add(jsonEncode({'type': 'finalize'}));
    } catch (_) {}
  }

  /// Sends the finalize signal and resolves once the provider has flushed all
  /// trailing tokens — detected by `finished: true` or by the token stream
  /// going quiet for [quiet] — capped by [timeout] as a safety net.
  ///
  /// Translation lags the source, so press-and-hold callers that stop on
  /// release must await this BEFORE [disconnect]; otherwise the socket closes
  /// before the translation arrives and it's silently dropped.
  Future<void> finalizeAndWait({
    Duration quiet = const Duration(milliseconds: 500),
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (_channel == null) return;
    _completeSettle(); // clear any stale waiter
    final completer = Completer<void>();
    _settleCompleter = completer;
    _settleQuiet = quiet;

    try {
      _channel!.sink.add(jsonEncode({'type': 'finalize'}));
    } catch (_) {
      _settleCompleter = null;
      return;
    }

    // Hard cap so a stalled stream can't hang the stop flow forever.
    Timer(timeout, _completeSettle);
    // Quiet-period timer; reset on every incoming token via _armSettleTimer.
    _armSettleTimer();
    return completer.future;
  }

  void _armSettleTimer() {
    if (_settleCompleter == null) return;
    _settleQuietTimer?.cancel();
    _settleQuietTimer = Timer(_settleQuiet, _completeSettle);
  }

  void _completeSettle() {
    _settleQuietTimer?.cancel();
    _settleQuietTimer = null;
    final c = _settleCompleter;
    _settleCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Drop everything in flight (in-flight tokens AND buffered audio) and
  /// reconnect on the same session. Audio captured during the brief
  /// reconnect gap is buffered and flushed to the new session, so the
  /// caller can keep streaming audio through the reset uninterrupted.
  ///
  /// Unlike [_rotateSession] (which flushes pending tokens via
  /// onTranscriptionCompleted before reconnecting), this method discards
  /// them — the caller wants the previous utterance gone, not emitted.
  Future<void> resetContext() async {
    if (_intentionallyClosed) return;
    if (_isReconnecting || _isRotating) return;
    _isRotating = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _subscription?.cancel();
    _subscription = null;
    _lateTranslationTimer?.cancel();

    // Discard, don't flush — the whole point is to drop the prior utterance.
    _resetTokenState();
    _clearAudioBuffer();
    _reconnectAttempts = 0;

    try {
      await _channel?.sink.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
    _channel = null;

    await _doConnect();

    // _doConnect clears _isRotating on success. If it failed silently, fall
    // back to normal reconnection so the service doesn't get stuck.
    if (_isRotating) {
      _isRotating = false;
      _tryReconnect();
    }
  }

  // ─── Reconnection ───

  void _tryReconnect() {
    if (_intentionallyClosed) return;
    // A reconnect is already scheduled — don't stack a second chain.
    if (_reconnectTimer != null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      onError
          ?.call('Connection lost. Please check your internet and try again.');
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;

    // Exponential backoff (1,2,4,8,16) capped at 30s, with ±30% jitter so a
    // fleet of clients dropped by the same proxy restart doesn't reconnect in
    // lockstep and hammer the proxy/Soniox in synchronized waves.
    final baseSeconds =
        (_reconnectAttempts <= 5) ? (1 << (_reconnectAttempts - 1)) : 30;
    final cappedSeconds = baseSeconds > 30 ? 30 : baseSeconds;
    final delayMs =
        (cappedSeconds * 1000 * (0.7 + _rand.nextDouble() * 0.6)).round();

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      if (!_intentionallyClosed) {
        _doConnect();
      }
    });
  }

  Future<void> ensureConnected() async {
    if (_intentionallyClosed) return;
    if (_channel != null && !_isReconnecting) return;

    // Cancel any pending reconnect so it can't fire during the async teardown
    // below and open a duplicate socket alongside the one we're about to make.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _isReconnecting = true;

    _subscription?.cancel();
    _subscription = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    await _doConnect();
  }

  void _resetTokenState() {
    _lateTranslationTimer?.cancel();
    _completeSettle();
    _pendingUtterance = '';
    _provisionalText = '';
    _pendingTranslation = '';
    _provisionalTranslation = '';
    _pendingWords.clear();
    currentSourceLanguage = null;
    currentTranslationSourceLanguage = null;
    // Speaker numbering restarts with each Soniox session (rotation/reconnect
    // included) — drop the old session's attribution state.
    currentSpeaker = null;
    _pendingSpeakerCounts.clear();
  }

  Future<void> disconnect() async {
    _intentionallyClosed = true;
    _isReconnecting = false;
    _isRotating = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopRotationTimer();
    _lateTranslationTimer?.cancel();
    _completeSettle();
    _clearAudioBuffer();
    _subscription?.cancel();
    _subscription = null;

    // Flush translation first (pairs with the pending utterance flushed
    // below; with no pending utterance to flush it's late — it belongs to
    // the last completed line). Trim-based so a whitespace-only source
    // buffer, which the transcript flush below drops, counts as no pairing.
    final pendingSourceText = (_pendingUtterance + _provisionalText).trim();
    if (_pendingTranslation.isNotEmpty || _provisionalTranslation.isNotEmpty) {
      final text = (_pendingTranslation + _provisionalTranslation).trim();
      if (text.isNotEmpty && !_hasRepetitionLoop(text)) {
        _emitTranslationCompleted(text, isLate: pendingSourceText.isEmpty);
      }
      _pendingTranslation = '';
      _provisionalTranslation = '';
    }

    // Then flush any remaining pending utterance (include provisional
    // text since user intentionally stopped — they saw it on screen)
    if (_pendingUtterance.isNotEmpty || _provisionalText.isNotEmpty) {
      final text = (_pendingUtterance + _provisionalText).trim();
      if (text.isNotEmpty) {
        lastCompletedWords = List.from(_pendingWords);
        _pendingWords.clear();
        _emitTranscriptionCompleted(text);
      }
      _pendingUtterance = '';
      _provisionalText = '';
    }

    try {
      await _channel?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _channel = null;
  }
}
