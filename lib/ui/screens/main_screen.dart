import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../models/transcript_session.dart';
import '../../models/word_timestamp.dart';
import '../../providers/recording_provider.dart';
import '../../providers/target_language_provider.dart';
import '../../providers/transcript_provider.dart';
import '../../providers/translation_provider.dart';
import '../../providers/session_history_provider.dart';
import '../../providers/display_mode_provider.dart';
import '../../providers/detected_language_provider.dart';
import '../../services/audio_service.dart';
import '../../services/soniox_realtime_service.dart';
import '../../services/database_service.dart';
import '../../services/elevenlabs_tts_service.dart';
import '../../providers/tts_provider.dart';
import '../../providers/speaker_provider.dart';
import '../../utils/constants.dart';
import '../widgets/transcript_panel.dart';
import '../widgets/record_button.dart';
import '../widgets/save_discard_row.dart';
import '../widgets/history_sheet.dart';
import '../widgets/status_bar.dart';
import '../widgets/line_by_line_panel.dart';
import '../widgets/conversation_panel.dart';
import '../../providers/conversation_provider.dart';
import '../widgets/friend_dialog.dart';
import '../widgets/session_invite_banner.dart';
import '../../services/user_service.dart';
import '../../services/sync_service.dart';
import '../../services/background_service.dart';
import 'live_session_screen.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with WidgetsBindingObserver {
  final AudioService _audioService = AudioService();
  final SonioxRealtimeService _sonioxService = SonioxRealtimeService();
  final ElevenLabsTtsService _ttsService = ElevenLabsTtsService();
  Timer? _newLineTimer;
  Timer? _newLineTimerTranslation;

  // Auto-TTS: fire TTS on draft text if source endpoint is slow
  Timer? _ttsDraftTimer;
  bool _ttsFiredForSegment = false;

  // Session invite state
  Map<String, dynamic>? _outgoingInvite;
  Map<String, dynamic>? _incomingInvite;
  Timer? _incomingPollTimer;
  Timer? _outgoingPollTimer;

  // Word timestamps per transcription line (for saved sessions)
  final List<List<WordTimestamp>> _wordTimestampsPerLine = [];

  // Guard against multiple stop taps
  bool _isStopping = false;

  // Suppress repeated error snackbars during reconnection
  DateTime? _lastErrorShown;

  // Autosave: periodic timer + session start timestamp
  Timer? _autosaveTimer;
  String? _sessionCreatedAt;

  // Track whether app actually went to paused (background), so we only
  // restart audio after a real suspension — not after Control Center, etc.
  bool _wasPaused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startIncomingPoll();
    _ttsService.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
        );
      }
    };
    // Restore any autosaved draft from a previous session
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreAutosaveDraft();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    _ttsDraftTimer?.cancel();
    _autosaveTimer?.cancel();
    _incomingPollTimer?.cancel();
    _outgoingPollTimer?.cancel();
    _audioService.dispose();
    _sonioxService.disconnect();
    _ttsService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final recordingState = ref.read(recordingStateProvider);
      if (recordingState == RecordingState.recording && _wasPaused) {
        // Only restart audio after a real background suspension (paused),
        // not after Control Center, notification banner, etc. (inactive).
        _resumeRecording();
      }
      _wasPaused = false;
    } else if (state == AppLifecycleState.paused) {
      _wasPaused = true;
      final recordingState = ref.read(recordingStateProvider);
      if (recordingState != RecordingState.idle) {
        _autosave();
      }
    } else if (state == AppLifecycleState.inactive) {
      // Transient state (Control Center, notification, app switcher animation).
      // Autosave defensively but don't restart audio on resume.
      final recordingState = ref.read(recordingStateProvider);
      if (recordingState != RecordingState.idle) {
        _autosave();
      }
    }
  }

  /// Restart both WebSocket and audio capture after returning from background.
  /// On iOS (no foreground service), the OS kills audio and network when
  /// suspended — so we must restart both, not just the WebSocket.
  Future<void> _resumeRecording() async {
    try {
      await _sonioxService.ensureConnected();
    } catch (_) {}
    try {
      // Restart audio capture (appends to existing temp PCM file)
      await _audioService.start();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resume microphone: $e')),
        );
      }
    }
  }

  void _startIncomingPoll() {
    _incomingPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_outgoingInvite != null || _incomingInvite != null) return;
      final invite = await UserService.instance.getIncomingInvite();
      if (mounted && invite != null && _incomingInvite == null) {
        setState(() => _incomingInvite = invite);
      }
    });
  }

  void _startOutgoingPoll(int inviteId) {
    _outgoingPollTimer?.cancel();
    _outgoingPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final status = await UserService.instance.getInviteStatus(inviteId);
      if (!mounted || status == null) return;

      final inviteStatus = status['status'] as String?;
      if (inviteStatus == 'accepted') {
        _outgoingPollTimer?.cancel();
        final sessionId = status['session_id'] as String;
        final partnerLanguage = status['to_language'] as String;
        final myLanguage = _outgoingInvite!['myLanguage'] as String;
        final friendCode = _outgoingInvite!['friendCode'] as String;
        setState(() => _outgoingInvite = null);
        _navigateToSession(sessionId, myLanguage, partnerLanguage, friendCode);
      } else if (inviteStatus == 'rejected' ||
          inviteStatus == 'expired' ||
          inviteStatus == 'cancelled') {
        _outgoingPollTimer?.cancel();
        setState(() => _outgoingInvite = null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Invite $inviteStatus')),
          );
        }
      }
    });
  }

  Future<void> _handleOutgoingInviteResult(Map<String, dynamic> data) async {
    if (data['status'] == 'accepted') {
      // Auto-accepted (they already sent us an invite)
      _navigateToSession(
        data['sessionId'] as String,
        data['myLanguage'] as String,
        data['partnerLanguage'] as String,
        data['friendCode'] as String,
      );
    } else {
      // Pending - start polling
      setState(() => _outgoingInvite = data);
      _startOutgoingPoll(data['inviteId'] as int);
    }
  }

  Future<void> _cancelOutgoingInvite() async {
    if (_outgoingInvite == null) return;
    _outgoingPollTimer?.cancel();
    await UserService.instance
        .cancelSessionInvite(_outgoingInvite!['inviteId'] as int);
    setState(() => _outgoingInvite = null);
  }

  Future<void> _acceptIncomingInvite() async {
    if (_incomingInvite == null) return;

    final language = await showDialog<TargetLanguage>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select your language'),
        children: TargetLanguage.values
            .map(
              (lang) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, lang),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(lang.displayName,
                      style: const TextStyle(fontSize: 16)),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (language == null) return;

    final inviteId = _incomingInvite!['id'] as int;
    final partnerLanguage = _incomingInvite!['from_language'] as String;
    final partnerCode = _incomingInvite!['from_friend_code'] as String;

    final result =
        await UserService.instance.acceptSessionInvite(inviteId, language.code);
    if (!mounted) return;

    if (result != null && result['success'] == true) {
      setState(() => _incomingInvite = null);
      _navigateToSession(
        result['sessionId'] as String,
        language.code,
        partnerLanguage,
        partnerCode,
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result?['error'] ?? 'Failed to accept invite')),
      );
    }
  }

  Future<void> _rejectIncomingInvite() async {
    if (_incomingInvite == null) return;
    await UserService.instance
        .rejectSessionInvite(_incomingInvite!['id'] as int);
    setState(() => _incomingInvite = null);
  }

  void _navigateToSession(String sessionId, String myLanguage,
      String partnerLanguage, String partnerFriendCode) {
    _incomingPollTimer?.cancel();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveSessionScreen(
          sessionId: sessionId,
          partnerLanguage: partnerLanguage,
          myLanguage: myLanguage,
          partnerFriendCode: partnerFriendCode,
        ),
      ),
    ).then((_) {
      // Restart polling when returning from session
      _startIncomingPoll();
    });
  }

  Future<void> _startRecording() async {
    final needsPermission = Platform.isAndroid || Platform.isIOS;
    final status = needsPermission
        ? await Permission.microphone.request()
        : PermissionStatus.granted;
    if (!status.isGranted) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Microphone Required'),
            content: const Text(
              'This app needs microphone access to transcribe Korean speech. '
              'Please enable it in Settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  openAppSettings();
                },
                child: const Text('Settings'),
              ),
            ],
          ),
        );
      }
      return;
    }

    // Clear drafts but keep history (so re-pressing mic continues the session)
    ref.read(koreanDraftProvider.notifier).state = '';
    ref.read(vietnameseDraftProvider.notifier).state = '';

    final targetLanguage = ref.read(targetLanguageProvider);

    // Update context with recent transcript to help model on reconnects
    final existingHistory = ref.read(koreanHistoryProvider);
    if (existingHistory.isNotEmpty) {
      _sonioxService.contextText =
          existingHistory.reversed.take(10).toList().reversed.join(' ');
    }

    // Set up language detection callback
    _sonioxService.onLanguageDetected = (language) {
      ref.read(detectedLanguageProvider.notifier).state = language;
    };

    // Set up Soniox transcription callbacks
    _sonioxService.onTranscriptionDraft = (draft, speaker) {
      ref.read(koreanDraftProvider.notifier).state = draft;
      if (speaker != null) {
        ref.read(draftSpeakerProvider.notifier).state = speaker;
      }
    };

    _sonioxService.onTranscriptionCompleted = (transcript, speaker) {
      if (transcript.isNotEmpty) {
        _newLineTimer?.cancel();
        final isLineByLine =
            ref.read(displayModeProvider) == DisplayMode.lineByLine;

        // Grab word timestamps for this utterance
        final words =
            List<WordTimestamp>.from(_sonioxService.lastCompletedWords);

        if (isLineByLine) {
          // Line-by-line: each Soniox endpoint = one segment.
          // We always ADD a new entry (never merge with previous).
          ref.read(koreanHistoryProvider.notifier).update(
                (state) => [...state, transcript],
              );
          // Pre-create empty slot — will be filled by onTranslationCompleted
          // which fires immediately after (flushed at source boundary).
          ref.read(vietnameseHistoryProvider.notifier).update(
                (state) => [...state, ''],
              );
          // Track speaker for this line
          ref.read(transcriptionSpeakersProvider.notifier).update(
                (state) => [...state, speaker],
              );
          ref.read(translationSpeakersProvider.notifier).update(
                (state) => [...state, speaker],
              );
          // Track word timestamps for this line
          _wordTimestampsPerLine.add(words);
          // No timer needed — segments are endpoint-delimited
        } else {
          // Split mode: append to last line, timer-based new lines
          ref.read(koreanHistoryProvider.notifier).update((state) {
            if (state.isEmpty) return [transcript];
            final updated = List<String>.from(state);
            updated.last = '${updated.last} $transcript';
            return updated;
          });
          // Track speaker for this line (first speaker wins)
          ref.read(transcriptionSpeakersProvider.notifier).update((state) {
            if (state.isEmpty) return [speaker];
            final updated = List<String?>.from(state);
            if (updated.last == null) updated.last = speaker;
            return updated;
          });
          // Merge word timestamps into last line
          if (_wordTimestampsPerLine.isEmpty) {
            _wordTimestampsPerLine.add(words);
          } else {
            _wordTimestampsPerLine.last = [
              ..._wordTimestampsPerLine.last,
              ...words
            ];
          }
          _newLineTimer = Timer(
            const Duration(milliseconds: AppConstants.newLinePauseMs),
            () {
              ref.read(koreanHistoryProvider.notifier).update(
                    (state) => [...state, ''],
                  );
              ref.read(transcriptionSpeakersProvider.notifier).update(
                    (state) => [...state, null],
                  );
              _wordTimestampsPerLine.add([]);
            },
          );
        }

        // Update context for next rotation with recent transcript
        final history = ref.read(koreanHistoryProvider);
        _sonioxService.contextText =
            history.reversed.take(10).toList().reversed.join(' ');
      }
      ref.read(koreanDraftProvider.notifier).state = '';
    };

    // Set up Soniox translation callbacks (used when target != Korean)
    _sonioxService.onTranslationDraft = (draft) {
      ref.read(vietnameseDraftProvider.notifier).state = draft;

      // Auto-TTS: debounce — if draft text settles for 1.5s without a source
      // endpoint firing, speak it now rather than waiting.
      _ttsDraftTimer?.cancel();
      if (draft.isNotEmpty &&
          !_ttsFiredForSegment &&
          _ttsService.enabled &&
          ElevenLabsTtsService.supportsLanguage(targetLanguage.code)) {
        _ttsDraftTimer = Timer(const Duration(milliseconds: 1500), () {
          final currentDraft = ref.read(vietnameseDraftProvider);
          if (currentDraft.isNotEmpty && !_ttsFiredForSegment) {
            _ttsFiredForSegment = true;
            _ttsService.speak(currentDraft);
          }
        });
      }
    };

    _sonioxService.onTranslationCompleted = (translation, speaker) {
      _ttsDraftTimer?.cancel();
      _newLineTimerTranslation?.cancel();

      // Send to TTS if enabled and not already fired from draft timer
      if (translation.isNotEmpty &&
          !_ttsFiredForSegment &&
          _ttsService.enabled &&
          ElevenLabsTtsService.supportsLanguage(targetLanguage.code)) {
        _ttsService.speak(translation);
      }
      _ttsFiredForSegment = false;

      final isLineByLine =
          ref.read(displayModeProvider) == DisplayMode.lineByLine;

      if (isLineByLine) {
        // Line-by-line: fill the earliest empty slot.
        // Always consume the slot even if translation is empty (short
        // utterance with no translation) — use ' ' placeholder so the
        // slot counts as filled and alignment stays in sync.
        ref.read(vietnameseHistoryProvider.notifier).update((state) {
          if (state.isEmpty) {
            return translation.isNotEmpty ? [translation] : state;
          }
          final updated = List<String>.from(state);
          for (int i = 0; i < updated.length; i++) {
            if (updated[i].isEmpty) {
              updated[i] = translation.isNotEmpty ? translation : ' ';
              return updated;
            }
          }
          // No empty slot — add as new entry
          if (translation.isNotEmpty) return [...updated, translation];
          return updated;
        });
      } else if (translation.isNotEmpty) {
        // Split mode: append to last line (ignore empty translations)
        ref.read(vietnameseHistoryProvider.notifier).update((state) {
          if (state.isEmpty) return [translation];
          final updated = List<String>.from(state);
          updated.last = '${updated.last} $translation';
          return updated;
        });
        // Track speaker for translation line (first speaker wins)
        ref.read(translationSpeakersProvider.notifier).update((state) {
          if (state.isEmpty) return [speaker];
          final updated = List<String?>.from(state);
          if (updated.last == null) updated.last = speaker;
          return updated;
        });
        _newLineTimerTranslation = Timer(
          const Duration(milliseconds: AppConstants.newLinePauseMs),
          () {
            ref.read(vietnameseHistoryProvider.notifier).update(
                  (state) => [...state, ''],
                );
            ref.read(translationSpeakersProvider.notifier).update(
                  (state) => [...state, null],
                );
          },
        );
      }
      ref.read(vietnameseDraftProvider.notifier).state = '';
    };

    _sonioxService.onError = (error) {
      if (!mounted) return;
      // Throttle error snackbars — show at most once per 10 seconds
      final now = DateTime.now();
      if (_lastErrorShown != null &&
          now.difference(_lastErrorShown!).inSeconds < 10) {
        return;
      }
      _lastErrorShown = now;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transcription error: $error')),
      );
    };

    // Set up audio callback
    _audioService.onAudioChunk = (bytes) {
      _sonioxService.sendAudio(bytes);
    };

    try {
      // Start foreground service first (Android) to prevent OS killing the app
      await BackgroundService.startRecordingService();
      await _sonioxService.connect(
        targetLanguageCode: targetLanguage.code,
        forceTranslation: targetLanguage == TargetLanguage.korean,
        languageHint: targetLanguage == TargetLanguage.korean ? '' : null,
      );
      await _audioService.start();
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
      // Start periodic autosave (every 15 seconds)
      _sessionCreatedAt ??= DateTime.now().toIso8601String();
      _autosaveTimer?.cancel();
      _autosaveTimer =
          Timer.periodic(const Duration(seconds: 15), (_) => _autosave());
      UserService.instance.reportActivity('recording_start');
    } catch (e) {
      await BackgroundService.stopRecordingService();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: $e')),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    // Guard against multiple taps while stopping
    if (_isStopping) return;
    _isStopping = true;

    // Immediately show processing state so user sees feedback
    ref.read(recordingStateProvider.notifier).state = RecordingState.processing;

    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    _ttsDraftTimer?.cancel();
    _ttsFiredForSegment = false;

    // Stop audio capture (timeout in case recorder is stuck after background)
    try {
      await _audioService.stop().timeout(const Duration(seconds: 5));
    } catch (_) {}

    // Finalize + disconnect Soniox (timeout in case WebSocket is stale)
    try {
      _sonioxService.finalize();
      await _sonioxService.disconnect().timeout(const Duration(seconds: 3));
    } catch (_) {}

    // Stop foreground service
    try {
      await BackgroundService.stopRecordingService()
          .timeout(const Duration(seconds: 3));
    } catch (_) {}

    // Don't stop TTS here — let queued segments finish playing
    _isStopping = false;
    _autosaveTimer?.cancel();
    if (mounted) {
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.postRecording;
      // Autosave immediately when recording stops
      _autosave();
    }
  }

  Future<void> _saveSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Session'),
        content: const Text('Save this transcription session?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    final rawKoreanHistory = ref.read(koreanHistoryProvider);
    final rawVietnameseHistory = ref.read(vietnameseHistoryProvider);
    final tSpeakers = ref.read(transcriptionSpeakersProvider);
    final tlSpeakers = ref.read(translationSpeakersProvider);

    final koreanHistory =
        rawKoreanHistory.where((s) => s.trim().isNotEmpty).toList();
    final vietnameseHistory =
        rawVietnameseHistory.where((s) => s.trim().isNotEmpty).toList();

    if (koreanHistory.isEmpty && vietnameseHistory.isEmpty) return;

    // Determine if we have multiple speakers
    final uniqueSpeakers = tSpeakers.where((s) => s != null).toSet();
    final hasMultiple = uniqueSpeakers.length > 1;

    String formatWithSpeakers(
        List<String> raw, List<String> filtered, List<String?> speakers) {
      if (!hasMultiple) return filtered.join('\n');
      final result = <String>[];
      int filteredIdx = 0;
      for (int i = 0; i < raw.length && filteredIdx < filtered.length; i++) {
        if (raw[i].trim().isEmpty) continue;
        final speaker = i < speakers.length ? speakers[i] : null;
        if (speaker != null) {
          result.add('${speakerLabel(speaker)}: ${filtered[filteredIdx]}');
        } else {
          result.add(filtered[filteredIdx]);
        }
        filteredIdx++;
      }
      return result.join('\n');
    }

    final koreanFull =
        formatWithSpeakers(rawKoreanHistory, koreanHistory, tSpeakers);
    final vietnameseFull =
        formatWithSpeakers(rawVietnameseHistory, vietnameseHistory, tlSpeakers);

    // Serialize word timestamps (per-line, aligned with raw history)
    String? timestampsJson;
    if (_wordTimestampsPerLine.isNotEmpty) {
      // Build per-line arrays matching rawKoreanHistory indices (filter empties)
      final tsPerLine = <List<Map<String, dynamic>>>[];
      for (int i = 0; i < rawKoreanHistory.length; i++) {
        if (rawKoreanHistory[i].trim().isEmpty) continue;
        final words = i < _wordTimestampsPerLine.length
            ? _wordTimestampsPerLine[i]
            : <WordTimestamp>[];
        tsPerLine.add(words.map((w) => w.toJson()).toList());
      }
      timestampsJson = jsonEncode(tsPerLine);
    }

    // Save audio file if available
    String? audioPath;
    if (_audioService.hasRecording) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      audioPath =
          await _audioService.saveRecordingAsWav('session_$timestamp.wav');
    }

    final session = TranscriptSession(
      createdAt: DateTime.now().toIso8601String(),
      koreanFull: koreanFull,
      vietnameseFull: vietnameseFull,
      koreanPreview: koreanFull.length > AppConstants.previewMaxLength
          ? koreanFull.substring(0, AppConstants.previewMaxLength)
          : koreanFull,
      vietnamesePreview: vietnameseFull.length > AppConstants.previewMaxLength
          ? vietnameseFull.substring(0, AppConstants.previewMaxLength)
          : vietnameseFull,
      audioPath: audioPath,
      timestampsJson: timestampsJson,
    );

    try {
      final id = await DatabaseService.instance.insertSession(session);
      ref.invalidate(sessionHistoryProvider);
      _audioService.clearRecording();
      // Upload to server (fire-and-forget)
      SyncService.instance.uploadSession(session);
      _resetState();
      if (mounted) {
        _showHistorySheetWithSession(context, id);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Save failed — try again'),
            action: SnackBarAction(label: 'Retry', onPressed: _saveSession),
          ),
        );
      }
    }
  }

  Future<void> _discardSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard Session'),
        content:
            const Text('Discard this transcription? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _audioService.clearRecording();
    _resetState();
  }

  void _showHistorySheet(BuildContext context, WidgetRef ref) {
    final headerHeight = MediaQuery.of(context).padding.top + 53;
    final screenHeight = MediaQuery.of(context).size.height;
    final sheetFraction =
        ((screenHeight - headerHeight) / screenHeight).clamp(0.5, 0.92);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppConstants.bgColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => HistorySheet(maxFraction: sheetFraction),
    );
  }

  void _showHistorySheetWithSession(BuildContext context, int sessionId) {
    final headerHeight = MediaQuery.of(context).padding.top + 53;
    final screenHeight = MediaQuery.of(context).size.height;
    final sheetFraction =
        ((screenHeight - headerHeight) / screenHeight).clamp(0.5, 0.92);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppConstants.bgColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => HistorySheet(
        maxFraction: sheetFraction,
        initialSessionId: sessionId,
      ),
    );
  }

  void _showFriendDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const FriendDialog(),
    );
    if (result != null && result['type'] == 'session_invite') {
      _handleOutgoingInviteResult(result);
    }
  }

  Future<void> _toggleTts() async {
    final current = ref.read(ttsEnabledProvider);
    if (current) {
      ref.read(ttsEnabledProvider.notifier).state = false;
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use Headphones'),
        content: const Text(
          'Please put on headphones or earphones before enabling voice '
          'translation. Without them, the TTS audio may be picked up by '
          'the microphone and re-transcribed as input.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(ttsEnabledProvider.notifier).state = true;
    }
  }

  // ── Autosave ───────────────────────────────────────────────────────

  Future<void> _autosave() async {
    final koreanHistory = ref.read(koreanHistoryProvider);
    final vietnameseHistory = ref.read(vietnameseHistoryProvider);

    // Don't save empty sessions
    if (koreanHistory.isEmpty && vietnameseHistory.isEmpty) return;

    _sessionCreatedAt ??= DateTime.now().toIso8601String();

    try {
      await DatabaseService.instance.saveAutosaveDraft({
        'korean_history': jsonEncode(koreanHistory),
        'vietnamese_history': jsonEncode(vietnameseHistory),
        'transcription_speakers':
            jsonEncode(ref.read(transcriptionSpeakersProvider)),
        'translation_speakers':
            jsonEncode(ref.read(translationSpeakersProvider)),
        'word_timestamps': jsonEncode(
          _wordTimestampsPerLine
              .map((line) => line.map((w) => w.toJson()).toList())
              .toList(),
        ),
        'target_language': ref.read(targetLanguageProvider).code,
        'created_at': _sessionCreatedAt!,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      // Silently ignore autosave failures — don't disrupt the user
    }
  }

  Future<void> _restoreAutosaveDraft() async {
    try {
      // Only restore if still idle (user hasn't started recording already)
      if (ref.read(recordingStateProvider) != RecordingState.idle) return;

      final draft = await DatabaseService.instance.getAutosaveDraft();
      if (draft == null) return;

      // Re-check after async gap — widget may be disposed or user tapped mic
      if (!mounted) return;
      if (ref.read(recordingStateProvider) != RecordingState.idle) return;

      final koreanHistory =
          (jsonDecode(draft['korean_history'] as String) as List)
              .cast<String>();
      final vietnameseHistory =
          (jsonDecode(draft['vietnamese_history'] as String) as List)
              .cast<String>();

      // Don't restore empty drafts
      if (koreanHistory.isEmpty && vietnameseHistory.isEmpty) {
        await DatabaseService.instance.clearAutosaveDraft();
        return;
      }

      ref.read(koreanHistoryProvider.notifier).state = koreanHistory;
      ref.read(vietnameseHistoryProvider.notifier).state = vietnameseHistory;

      // Restore speakers
      if (draft['transcription_speakers'] != null) {
        ref.read(transcriptionSpeakersProvider.notifier).state =
            (jsonDecode(draft['transcription_speakers'] as String) as List)
                .map((e) => e as String?)
                .toList();
      }
      if (draft['translation_speakers'] != null) {
        ref.read(translationSpeakersProvider.notifier).state =
            (jsonDecode(draft['translation_speakers'] as String) as List)
                .map((e) => e as String?)
                .toList();
      }

      // Restore word timestamps
      if (draft['word_timestamps'] != null) {
        final tsData = jsonDecode(draft['word_timestamps'] as String) as List;
        _wordTimestampsPerLine.clear();
        for (final line in tsData) {
          _wordTimestampsPerLine.add(
            (line as List)
                .map((w) => WordTimestamp.fromJson(w as Map<String, dynamic>))
                .toList(),
          );
        }
      }

      // Restore target language
      final targetCode = draft['target_language'] as String;
      final targetLang = TargetLanguage.values.where(
        (l) => l.code == targetCode,
      );
      if (targetLang.isNotEmpty) {
        ref.read(targetLanguageProvider.notifier).state = targetLang.first;
      }

      _sessionCreatedAt = draft['created_at'] as String;

      // Set state to postRecording so user sees save/discard buttons
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.postRecording;

      // Show recovery notification
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recovered unsaved session'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      // If restore fails, clear the draft and continue normally
      await DatabaseService.instance.clearAutosaveDraft();
    }
  }

  // ── Conversation Mode Recording ──────────────────────────────────

  Future<void> _startConversationRecording(ConversationSpeaker speaker) async {
    final needsPermission = Platform.isAndroid || Platform.isIOS;
    final status = needsPermission
        ? await Permission.microphone.request()
        : PermissionStatus.granted;
    if (!status.isGranted) return;

    ref.read(activeConversationSpeakerProvider.notifier).state = speaker;
    ref.read(conversationDraftOriginalProvider.notifier).state = '';
    ref.read(conversationDraftTranslatedProvider.notifier).state = '';

    // Determine source and target language based on who is speaking
    final myLang = ref.read(myLanguageProvider);
    final theirLang = ref.read(theirLanguageProvider);
    // Bottom person speaks myLang → translate to theirLang
    // Top person speaks theirLang → translate to myLang
    final sourceLang =
        speaker == ConversationSpeaker.bottom ? myLang : theirLang;
    final targetLang =
        speaker == ConversationSpeaker.bottom ? theirLang : myLang;

    // Set up Soniox callbacks for conversation mode
    _sonioxService.onTranscriptionDraft = (draft, spk) {
      ref.read(conversationDraftOriginalProvider.notifier).state = draft;
    };

    _sonioxService.onTranscriptionCompleted = (transcript, spk) {
      if (transcript.isNotEmpty) {
        // Add message with original text, translation will be filled by onTranslationCompleted
        final msg = ConversationMessage(
          speaker: speaker,
          originalText: transcript,
        );
        ref.read(conversationMessagesProvider.notifier).update(
              (state) => [...state, msg],
            );
      }
      ref.read(conversationDraftOriginalProvider.notifier).state = '';
    };

    _sonioxService.onTranslationDraft = (draft) {
      ref.read(conversationDraftTranslatedProvider.notifier).state = draft;
    };

    _sonioxService.onTranslationCompleted = (translation, spk) {
      if (translation.isNotEmpty) {
        // Fill translation on the last message from this speaker that has no translation
        ref.read(conversationMessagesProvider.notifier).update((state) {
          final updated = List<ConversationMessage>.from(state);
          for (int i = updated.length - 1; i >= 0; i--) {
            if (updated[i].speaker == speaker &&
                updated[i].translatedText.isEmpty) {
              updated[i] = updated[i].copyWith(translatedText: translation);
              break;
            }
          }
          return updated;
        });
      }
      ref.read(conversationDraftTranslatedProvider.notifier).state = '';
    };

    _sonioxService.onLanguageDetected = (language) {
      ref.read(detectedLanguageProvider.notifier).state = language;
    };

    _sonioxService.onError = (error) {
      if (!mounted) return;
      final now = DateTime.now();
      if (_lastErrorShown != null &&
          now.difference(_lastErrorShown!).inSeconds < 10) {
        return;
      }
      _lastErrorShown = now;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transcription error: $error')),
      );
    };

    _audioService.onAudioChunk = (bytes) {
      _sonioxService.sendAudio(bytes);
    };

    try {
      await BackgroundService.startRecordingService();
      await _sonioxService.connect(
        targetLanguageCode: targetLang.code,
        forceTranslation: true,
        languageHint: sourceLang.code,
      );
      await _audioService.start();
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
    } catch (e) {
      await BackgroundService.stopRecordingService();
      ref.read(activeConversationSpeakerProvider.notifier).state = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: $e')),
        );
      }
    }
  }

  Future<void> _stopConversationRecording() async {
    if (_isStopping) return;
    _isStopping = true;

    ref.read(recordingStateProvider.notifier).state = RecordingState.processing;

    try {
      await _audioService.stop().timeout(const Duration(seconds: 5));
    } catch (_) {}

    try {
      _sonioxService.finalize();
      await _sonioxService.disconnect().timeout(const Duration(seconds: 3));
    } catch (_) {}

    try {
      await BackgroundService.stopRecordingService()
          .timeout(const Duration(seconds: 3));
    } catch (_) {}

    _isStopping = false;
    _audioService.clearRecording();
    ref.read(activeConversationSpeakerProvider.notifier).state = null;
    if (mounted) {
      ref.read(recordingStateProvider.notifier).state = RecordingState.idle;
    }
  }

  void _clearConversation() {
    ref.read(conversationMessagesProvider.notifier).state = [];
    ref.read(conversationDraftOriginalProvider.notifier).state = '';
    ref.read(conversationDraftTranslatedProvider.notifier).state = '';
  }

  void _swapConversationLanguages() {
    final myLang = ref.read(myLanguageProvider);
    final theirLang = ref.read(theirLanguageProvider);
    ref.read(myLanguageProvider.notifier).state = theirLang;
    ref.read(theirLanguageProvider.notifier).state = myLang;
  }

  void _resetState() {
    _autosaveTimer?.cancel();
    _sessionCreatedAt = null;
    DatabaseService.instance.clearAutosaveDraft();
    ref.read(recordingStateProvider.notifier).state = RecordingState.idle;
    ref.read(koreanDraftProvider.notifier).state = '';
    ref.read(koreanHistoryProvider.notifier).state = [];
    ref.read(vietnameseDraftProvider.notifier).state = '';
    ref.read(vietnameseHistoryProvider.notifier).state = [];
    ref.read(transcriptionSpeakersProvider.notifier).state = [];
    ref.read(translationSpeakersProvider.notifier).state = [];
    ref.read(draftSpeakerProvider.notifier).state = null;
    ref.read(detectedLanguageProvider.notifier).state = null;
    _wordTimestampsPerLine.clear();
    _sonioxService.contextText = null;
    _ttsService.stop();
    // Conversation state
    ref.read(conversationMessagesProvider.notifier).state = [];
    ref.read(conversationDraftOriginalProvider.notifier).state = '';
    ref.read(conversationDraftTranslatedProvider.notifier).state = '';
    ref.read(activeConversationSpeakerProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
    final recordingState = ref.watch(recordingStateProvider);
    final koreanDraft = ref.watch(koreanDraftProvider);
    final koreanHistory = ref.watch(koreanHistoryProvider);
    final vietnameseDraft = ref.watch(vietnameseDraftProvider);
    final vietnameseHistory = ref.watch(vietnameseHistoryProvider);

    final targetLanguage = ref.watch(targetLanguageProvider);
    final displayMode = ref.watch(displayModeProvider);
    final ttsEnabled = ref.watch(ttsEnabledProvider);
    final transcriptionSpeakers = ref.watch(transcriptionSpeakersProvider);
    final translationSpeakers = ref.watch(translationSpeakersProvider);
    final draftSpeaker = ref.watch(draftSpeakerProvider);
    final detectedLanguage = ref.watch(detectedLanguageProvider);

    // Sync TTS service state with provider
    _ttsService.setLanguageCode(targetLanguage.code);
    _ttsService.setEnabled(ttsEnabled);

    // Show speaker toggle for languages with TTS support + valid API key
    final showTtsToggle =
        ElevenLabsTtsService.supportsLanguage(targetLanguage.code) &&
            ElevenLabsTtsService.hasApiKey;

    final isRecordingOrProcessing =
        recordingState == RecordingState.recording ||
            recordingState == RecordingState.processing;
    final isPostRecording = recordingState == RecordingState.postRecording;

    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Session invite banners
            if (_incomingInvite != null)
              IncomingInviteBanner(
                friendCode:
                    _incomingInvite!['from_friend_code'] as String? ?? '?',
                onAccept: _acceptIncomingInvite,
                onReject: _rejectIncomingInvite,
              ),
            if (_outgoingInvite != null)
              OutgoingInviteBanner(
                friendCode: _outgoingInvite!['friendCode'] as String? ?? '?',
                onCancel: _cancelOutgoingInvite,
              ),

            // Header: Title + Status
            Padding(
              padding: const EdgeInsets.only(
                left: AppConstants.panelPaddingH,
                top: 17,
                bottom: 12,
                right: AppConstants.panelPaddingH,
              ),
              child: Row(
                children: [
                  const Text(
                    'Silsigan',
                    style: TextStyle(
                      fontSize: AppConstants.titleFontSize,
                      fontWeight: FontWeight.w600,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  StatusBar(state: recordingState),
                  const Spacer(),
                  GestureDetector(
                    onTap: _showFriendDialog,
                    child: const Icon(
                      Icons.person_add_outlined,
                      size: 24,
                      color: AppConstants.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  PopupMenuButton<DisplayMode>(
                    onSelected: (mode) {
                      ref.read(displayModeProvider.notifier).state = mode;
                    },
                    offset: const Offset(0, 40),
                    itemBuilder: (context) {
                      final current = ref.read(displayModeProvider);
                      return [
                        PopupMenuItem<DisplayMode>(
                          value: DisplayMode.lineByLine,
                          child: Row(
                            children: [
                              const Expanded(child: Text('Line by Line')),
                              if (current == DisplayMode.lineByLine)
                                const Icon(Icons.check, size: 18),
                            ],
                          ),
                        ),
                        PopupMenuItem<DisplayMode>(
                          value: DisplayMode.split,
                          child: Row(
                            children: [
                              const Expanded(child: Text('Split View')),
                              if (current == DisplayMode.split)
                                const Icon(Icons.check, size: 18),
                            ],
                          ),
                        ),
                        PopupMenuItem<DisplayMode>(
                          value: DisplayMode.conversation,
                          child: Row(
                            children: [
                              const Expanded(child: Text('Conversation')),
                              if (current == DisplayMode.conversation)
                                const Icon(Icons.check, size: 18),
                            ],
                          ),
                        ),
                      ];
                    },
                    child: const Icon(
                      Icons.settings_outlined,
                      size: 24,
                      color: AppConstants.textSecondary,
                    ),
                  ),
                ],
              ),
            ),

            // Content area: Conversation / Split / Line-by-Line
            if (displayMode == DisplayMode.conversation) ...[
              Expanded(
                child: ConversationPanel(
                  messages: ref.watch(conversationMessagesProvider),
                  draftOriginal: ref.watch(conversationDraftOriginalProvider),
                  draftTranslated: ref.watch(conversationDraftTranslatedProvider),
                  activeSpeaker: ref.watch(activeConversationSpeakerProvider),
                  recordingState: recordingState,
                  myLanguage: ref.watch(myLanguageProvider),
                  theirLanguage: ref.watch(theirLanguageProvider),
                  onBottomMicStart: () =>
                      _startConversationRecording(ConversationSpeaker.bottom),
                  onBottomMicStop: _stopConversationRecording,
                  onTopMicStart: () =>
                      _startConversationRecording(ConversationSpeaker.top),
                  onTopMicStop: _stopConversationRecording,
                  onSwapLanguages: _swapConversationLanguages,
                  onClear: _clearConversation,
                  onMyLanguageChanged: (lang) =>
                      ref.read(myLanguageProvider.notifier).state = lang,
                  onTheirLanguageChanged: (lang) =>
                      ref.read(theirLanguageProvider.notifier).state = lang,
                ),
              ),
            ] else ...[
              if (displayMode == DisplayMode.split) ...[
                Expanded(
                  child: TranscriptPanel(
                    history: koreanHistory,
                    draft: koreanDraft,
                    label: 'Transcription',
                    showCursor: isRecordingOrProcessing && koreanDraft.isNotEmpty,
                    roundedTop: true,
                    speakers: transcriptionSpeakers,
                    draftSpeaker: draftSpeaker,
                  ),
                ),
                Container(
                  height: 5,
                  color: AppConstants.dividerColor,
                ),
                Expanded(
                  child: TranscriptPanel(
                    history: vietnameseHistory,
                    draft: vietnameseDraft,
                    label: 'Translation',
                    showEllipsis:
                        isRecordingOrProcessing && vietnameseDraft.isNotEmpty,
                    showSpeakerToggle: showTtsToggle,
                    speakerEnabled: ttsEnabled,
                    onSpeakerToggle: _toggleTts,
                    speakers: translationSpeakers,
                    draftSpeaker: draftSpeaker,
                  ),
                ),
              ] else
                Expanded(
                  child: LineByLinePanel(
                    transcriptionHistory: koreanHistory,
                    transcriptionDraft: koreanDraft,
                    translationHistory: vietnameseHistory,
                    translationDraft: vietnameseDraft,
                    isRecording: isRecordingOrProcessing,
                    showSpeakerToggle: showTtsToggle,
                    speakerEnabled: ttsEnabled,
                    onSpeakerToggle: _toggleTts,
                    onSpeakLine: (text) => _ttsService.speakOnce(text),
                    ttsLineState: showTtsToggle ? _ttsService.lineState : null,
                    speakers: transcriptionSpeakers,
                    draftSpeaker: draftSpeaker,
                  ),
                ),

              // Bottom Controls Area (only for non-conversation modes)
              Container(
                color: AppConstants.bgColor,
                padding: const EdgeInsets.only(top: 20),
                child: Column(
                  children: [
                    // Language Selector Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Container(
                            key: ValueKey(detectedLanguage ?? 'any'),
                            width: AppConstants.langBoxWidth,
                            height: AppConstants.langBoxHeight,
                            decoration: BoxDecoration(
                              color: AppConstants.panelColor,
                              borderRadius: BorderRadius.circular(
                                AppConstants.langBoxRadius,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              detectedLanguage != null
                                  ? languageDisplayName(detectedLanguage)
                                  : 'Any',
                              style: const TextStyle(
                                fontSize: AppConstants.langFontSize,
                                color: AppConstants.textPrimary,
                              ),
                            ),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(
                            Icons.arrow_forward,
                            size: 27,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                        PopupMenuButton<TargetLanguage>(
                          enabled: !isRecordingOrProcessing,
                          onSelected: (lang) {
                            ref.read(targetLanguageProvider.notifier).state =
                                lang;
                          },
                          offset: const Offset(0, -160),
                          itemBuilder: (context) => TargetLanguage.values
                              .map(
                                (lang) => PopupMenuItem<TargetLanguage>(
                                  value: lang,
                                  child: Row(
                                    children: [
                                      Expanded(child: Text(lang.displayName)),
                                      if (lang == targetLanguage)
                                        const Icon(Icons.check, size: 18),
                                    ],
                                  ),
                                ),
                              )
                              .toList(),
                          child: Container(
                            width: AppConstants.langBoxWidth,
                            height: AppConstants.langBoxHeight,
                            decoration: BoxDecoration(
                              color: AppConstants.panelColor,
                              borderRadius: BorderRadius.circular(
                                AppConstants.langBoxRadius,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              targetLanguage.displayName,
                              style: const TextStyle(
                                fontSize: AppConstants.langFontSize,
                                color: AppConstants.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 32),

                    // Action Buttons Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Left button: History (idle) / hidden (recording) / Trash (post)
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 120),
                          child: isRecordingOrProcessing
                              ? SizedBox(
                                  key: const ValueKey('left-hidden'),
                                  width: AppConstants.sideButtonSize,
                                )
                              : isPostRecording
                                  ? BottomSideButton(
                                      key: const ValueKey('left-trash'),
                                      icon: Icons.delete_outline,
                                      backgroundColor: Colors.red,
                                      onTap: _discardSession,
                                    )
                                  : BottomSideButton(
                                      key: const ValueKey('left-history'),
                                      icon: Icons.history,
                                      backgroundColor:
                                          AppConstants.historyButtonColor,
                                      onTap: () =>
                                          _showHistorySheet(context, ref),
                                    ),
                        ),
                        const SizedBox(width: 40),

                        // Center button: Mic (idle/post) / Stop (recording)
                        RecordButton(
                          state: recordingState,
                          onStart: _startRecording,
                          onStop: _stopRecording,
                        ),
                        const SizedBox(width: 40),

                        // Right button: Check (idle/post) / hidden (recording)
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 120),
                          child: isRecordingOrProcessing
                              ? SizedBox(
                                  key: const ValueKey('right-hidden'),
                                  width: AppConstants.sideButtonSize,
                                )
                              : BottomSideButton(
                                  key: ValueKey(
                                      'right-check-${isPostRecording}'),
                                  icon: Icons.check,
                                  backgroundColor: isPostRecording
                                      ? AppConstants.saveButtonActiveColor
                                      : AppConstants.saveButtonColor,
                                  onTap: isPostRecording ? _saveSession : null,
                                ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
