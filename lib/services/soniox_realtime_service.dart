import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
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
  static const _apiKey = String.fromEnvironment('SONIOX_API_KEY');

  // Transcription token state
  String _pendingUtterance = '';
  String _provisionalText = '';

  // Translation token state
  String _pendingTranslation = '';
  String _provisionalTranslation = '';

  // Stored for reconnect
  String? _targetLanguageCode;

  // Speaker diarization
  String? _currentSpeaker;

  // Language identification
  String? _lastDetectedLanguage;

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

  // Callbacks
  Function(String draft, String? speaker)? onTranscriptionDraft;
  Function(String transcript, String? speaker)? onTranscriptionCompleted;
  Function(String draft)? onTranslationDraft;
  Function(String translation, String? speaker)? onTranslationCompleted;
  Function(String error)? onError;
  Function()? onConnected;
  Function(String language)? onLanguageDetected;

  bool _forceTranslation = false;
  String? _languageHint;

  bool get isConnected => _channel != null && !_isReconnecting;

  Future<void> connect({
    String? targetLanguageCode,
    bool forceTranslation = false,
    String? languageHint,
  }) async {
    _intentionallyClosed = false;
    _reconnectAttempts = 0;
    _targetLanguageCode = targetLanguageCode;
    _forceTranslation = forceTranslation;
    _languageHint = languageHint;
    _resetTokenState();
    _clearAudioBuffer();
    await _doConnect();
    _startRotationTimer();
  }

  Future<void> _doConnect() async {
    try {
      _channel = IOWebSocketChannel.connect(
        Uri.parse(AppConstants.sonioxRealtimeUrl),
        pingInterval: const Duration(seconds: 15),
      );

      final config = <String, dynamic>{
        'api_key': _apiKey,
        'model': AppConstants.sonioxModel,
        'audio_format': AppConstants.audioFormat,
        'sample_rate': AppConstants.sampleRate,
        'num_channels': AppConstants.numChannels,
        'enable_endpoint_detection': true,
        'max_endpoint_delay_ms': AppConstants.endpointDelayMs,
        'enable_speaker_diarization': true,
        'enable_language_identification': true,
      };

      // Only send language hint if provided (empty = let Soniox auto-detect)
      final hint = _languageHint ?? AppConstants.transcriptionLanguage;
      if (hint.isNotEmpty) {
        config['language_hints'] = [hint];
      }

      if (_targetLanguageCode != null &&
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

      _channel!.sink.add(jsonEncode(config));

      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          _handleDisconnect('stream error: $error');
        },
        onDone: () {
          _handleDisconnect('stream closed');
        },
      );

      _reconnectAttempts = 0;
      _isReconnecting = false;
      _isRotating = false;

      _flushAudioBuffer();
      onConnected?.call();
    } catch (e) {
      _handleDisconnect('connect error: $e');
    }
  }

  void _handleDisconnect(String reason) {
    if (_intentionallyClosed) return;

    _subscription?.cancel();
    _subscription = null;
    _channel = null;

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
    if (_pendingTranslation.isNotEmpty || _provisionalTranslation.isNotEmpty) {
      final text = (_pendingTranslation + _provisionalTranslation).trim();
      // Only emit if it's not garbage (passes repetition check)
      if (text.isNotEmpty && !_hasRepetitionLoop(text)) {
        onTranslationCompleted?.call(text, _currentSpeaker);
      }
      _pendingTranslation = '';
      _provisionalTranslation = '';
    }
    if (_pendingUtterance.isNotEmpty) {
      final text = _pendingUtterance.trim();
      if (text.isNotEmpty && !_hasRepetitionLoop(text)) {
        lastCompletedWords = List.from(_pendingWords);
        onTranscriptionCompleted?.call(text, _currentSpeaker);
      }
      _pendingUtterance = '';
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

  // ─── Token processing ───

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

      if (data['error_code'] != null) {
        final errorMsg =
            data['error_message'] as String? ?? 'Unknown Soniox error';
        onError?.call(errorMsg);
        return;
      }

      if (data['finished'] == true) return;

      final tokens = data['tokens'] as List<dynamic>?;
      if (tokens == null || tokens.isEmpty) return;

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
      onError?.call('Failed to parse message: $e');
    }
  }

  void _processSourceTokens(List<Map<String, dynamic>> tokens) {
    final hadProvisional = _provisionalText.isNotEmpty;
    String newProvisionalText = '';
    String newFinalText = '';

    for (final token in tokens) {
      final text = token['text'] as String? ?? '';
      final isFinal = token['is_final'] as bool? ?? false;
      final speaker = token['speaker'] as String?;
      final language = token['language'] as String?;
      if (speaker != null) _currentSpeaker = speaker;
      if (language != null && language != _lastDetectedLanguage) {
        _lastDetectedLanguage = language;
        onLanguageDetected?.call(language);
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
        onTranscriptionCompleted?.call(text, _currentSpeaker);
      }
      _pendingUtterance = '';
      _provisionalText = '';
      _pendingWords.clear();
      _rotateSession();
      return;
    }

    onTranscriptionDraft?.call(_provisionalText, _currentSpeaker);

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
      onTranslationCompleted?.call(fullTranslation, _currentSpeaker);
      _pendingTranslation = '';
      _provisionalTranslation = '';

      lastCompletedWords = List.from(_pendingWords);
      _pendingWords.clear();
      onTranscriptionCompleted?.call(_pendingUtterance.trim(), _currentSpeaker);
      _pendingUtterance = '';
    }
  }

  void _processTranslationTokens(List<Map<String, dynamic>> tokens) {
    String newProvisionalText = '';
    String newFinalText = '';

    for (final token in tokens) {
      final text = token['text'] as String? ?? '';
      final isFinal = token['is_final'] as bool? ?? false;
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
        onTranslationCompleted?.call(text, _currentSpeaker);
      }
      _pendingTranslation = '';
      _provisionalTranslation = '';
      _rotateSession();
      return;
    }

    onTranslationDraft?.call(_pendingTranslation + _provisionalTranslation);
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

  // ─── Reconnection ───

  void _tryReconnect() {
    if (_intentionallyClosed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      onError
          ?.call('Connection lost. Please check your internet and try again.');
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;

    final delaySeconds =
        (_reconnectAttempts <= 4) ? (1 << (_reconnectAttempts - 1)) : 15;

    Future.delayed(Duration(seconds: delaySeconds), () {
      if (!_intentionallyClosed) {
        _doConnect();
      }
    });
  }

  Future<void> ensureConnected() async {
    if (_intentionallyClosed) return;
    if (_channel != null && !_isReconnecting) return;

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
    _pendingUtterance = '';
    _provisionalText = '';
    _pendingTranslation = '';
    _provisionalTranslation = '';
    _pendingWords.clear();
  }

  Future<void> disconnect() async {
    _intentionallyClosed = true;
    _isReconnecting = false;
    _isRotating = false;
    _stopRotationTimer();
    _clearAudioBuffer();
    _subscription?.cancel();
    _subscription = null;

    // Flush translation first (fills the last segment's empty slot)
    if (_pendingTranslation.isNotEmpty) {
      final text = _pendingTranslation.trim();
      if (text.isNotEmpty && !_hasRepetitionLoop(text)) {
        onTranslationCompleted?.call(text, _currentSpeaker);
      }
      _pendingTranslation = '';
    }

    // Then flush any remaining pending utterance
    if (_pendingUtterance.isNotEmpty) {
      lastCompletedWords = List.from(_pendingWords);
      _pendingWords.clear();
      onTranscriptionCompleted?.call(_pendingUtterance.trim(), _currentSpeaker);
      _pendingUtterance = '';
    }

    try {
      await _channel?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _channel = null;
  }
}
