import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
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
import '../../services/update_service.dart';
import 'live_session_screen.dart';

/// Strip leading whitespace and leading punctuation (+ trailing space) so that
/// a displayed line never visually starts with a space or dangling punctuation.
String _cleanLineStart(String text) {
  text = text.trimLeft();
  return text.replaceFirst(RegExp(r'^[,.\-;:!?、。，；：！？…·]+\s*'), '');
}

/// Count sentence-ending punctuation in [text].
/// Treats ellipsis (... or …) as a single sentence boundary.
int _countSentences(String text) {
  return RegExp(r'\.{2,}|[.?!。…？！]').allMatches(text).length;
}

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
  Timer? _sentenceBreakTimer;
  bool _translationNewLinePending = false;

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

  // Analytics: track recording duration
  DateTime? _recordingStartedAt;

  // Track whether app actually went to paused (background), so we only
  // restart audio after a real suspension — not after Control Center, etc.
  bool _wasPaused = false;

  // Usage limit tracking
  int _usedSeconds = 0;
  int _limitMinutes = 30;
  Timer? _usageLimitTimer;
  static const _isPrivateMode =
      String.fromEnvironment('SONIOX_PRIVATE') == 'true';
  bool _isPrivateUser = false;
  bool get _isPrivate => _isPrivateMode || _isPrivateUser;

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
    // Restore saved languages and autosaved draft
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreSavedLanguages();
      _restoreAutosaveDraft();
      _checkForUpdate();
      _fetchUsage();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    _sentenceBreakTimer?.cancel();
    _ttsDraftTimer?.cancel();
    _autosaveTimer?.cancel();
    _incomingPollTimer?.cancel();
    _outgoingPollTimer?.cancel();
    _usageLimitTimer?.cancel();
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

  // ── Usage Limit ─────────────��──────────────────────────────────

  Future<void> _fetchUsage() async {
    if (_isPrivateMode) return; // compile-time private skips fetch entirely
    final usage = await UserService.instance.fetchUsage();
    if (usage != null && mounted) {
      setState(() {
        // Only accept server value if >= local (avoids race where
        // _fetchUsage returns before reportActivity is processed)
        final serverUsed = usage['usedSeconds'] as int;
        if (serverUsed >= _usedSeconds) {
          _usedSeconds = serverUsed;
        }
        _limitMinutes = usage['limitMinutes'] as int;
        _isPrivateUser = usage['isPrivate'] as bool;
      });
    }
  }

  int get _remainingSeconds {
    final remaining = _limitMinutes * 60 - _usedSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  bool get _usageLimitReached => !_isPrivate && _remainingSeconds <= 0;

  void _startUsageLimitTimer() {
    _usageLimitTimer?.cancel();
    if (_isPrivate) return;
    final remainingSecs = _limitMinutes * 60 - _usedSeconds;
    if (remainingSecs <= 0) {
      _forceStopForUsageLimit();
      return;
    }
    // One-shot timer that fires exactly when the limit is reached
    _usageLimitTimer = Timer(Duration(seconds: remainingSecs), () {
      _forceStopForUsageLimit();
    });
  }

  Future<void> _forceStopForUsageLimit() async {
    final recordingState = ref.read(recordingStateProvider);
    if (recordingState == RecordingState.recording) {
      final displayMode = ref.read(displayModeProvider);
      if (displayMode == DisplayMode.conversation) {
        await _stopConversationRecording();
      } else {
        await _stopRecording();
      }
    }
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Usage Limit Reached'),
          content: const Text(
            'You have used all your available minutes. '
            'Purchase more time to continue.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _showPurchasePage() async {
    const packages = [
      {'hours': 1, 'price': '15,000', 'label': '1 Hour', 'per': '15,000₫/hr'},
      {'hours': 5, 'price': '75,000', 'label': '5 Hours', 'per': '15,000₫/hr'},
      {
        'hours': 10,
        'price': '139,000',
        'label': '10 Hours',
        'per': '13,900₫/hr',
        'badge': 'POPULAR'
      },
      {
        'hours': 30,
        'price': '369,000',
        'label': '30 Hours',
        'per': '12,300₫/hr',
        'badge': 'SAVE 18%'
      },
      {
        'hours': 50,
        'price': '599,000',
        'label': '50 Hours',
        'per': '11,980₫/hr',
        'badge': 'BEST VALUE'
      },
    ];

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Add More Time',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'Sign in to purchase more time',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // Locked sign-in buttons
                _buildLockedSignInButton(
                  ctx,
                  icon: Icons.g_mobiledata,
                  label: 'Continue with Google',
                  color: Colors.white,
                  textColor: Colors.black87,
                  borderColor: Colors.grey.shade300,
                ),
                const SizedBox(height: 10),
                _buildLockedSignInButton(
                  ctx,
                  icon: Icons.apple,
                  label: 'Continue with Apple',
                  color: Colors.black87,
                  textColor: Colors.white,
                ),
                const SizedBox(height: 6),
                Text(
                  'Coming soon',
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(child: Divider(color: Colors.grey[300])),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'or',
                        style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                      ),
                    ),
                    Expanded(child: Divider(color: Colors.grey[300])),
                  ],
                ),
                const SizedBox(height: 12),

                // Redeem code section
                _RedeemCodeSection(
                  onRedeemed: (usedSec, limitMin) {
                    setState(() {
                      _usedSeconds = usedSec;
                      _limitMinutes = limitMin;
                    });
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code redeemed!')),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLockedSignInButton(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    required Color color,
    required Color textColor,
    Color? borderColor,
  }) {
    return Opacity(
      opacity: 0.5,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: borderColor != null ? Border.all(color: borderColor) : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Sign-in coming soon')),
              );
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: textColor, size: 24),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.lock_outline, color: textColor, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startRecording() async {
    // Check usage limit before starting
    if (_usageLimitReached) {
      _forceStopForUsageLimit();
      return;
    }

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

    // Cancel any stale timers from previous recording flush
    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    _sentenceBreakTimer?.cancel();
    _sentenceBreakTimer = null;

    // Clear drafts but keep history (so re-pressing mic continues the session)
    ref.read(koreanDraftProvider.notifier).state = '';
    ref.read(vietnameseDraftProvider.notifier).state = '';

    final targetLanguage = ref.read(targetLanguageProvider);
    final isTranscriptionOnly =
        ref.read(displayModeProvider) == DisplayMode.transcription;

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
    _sonioxService.onTranscriptionDraft = (draft) {
      ref.read(koreanDraftProvider.notifier).state = draft;
      // Cancel the newline timer while draft text is active so the
      // paragraph break can't fire mid-draft (which would make the
      // draft jump from inline to a new line unexpectedly).
      if (draft.isNotEmpty) _newLineTimer?.cancel();
    };

    _sonioxService.onTranscriptionCompleted = (transcript) {
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
                (state) => [...state, _cleanLineStart(transcript)],
              );
          // Pre-create empty slot — will be filled by onTranslationCompleted
          // which fires immediately after (flushed at source boundary).
          ref.read(vietnameseHistoryProvider.notifier).update(
                (state) => [...state, ''],
              );
          // Track word timestamps for this line
          _wordTimestampsPerLine.add(words);
          // No timer needed — segments are endpoint-delimited
        } else {
          // Split mode: append to last line, timer-based new lines
          ref.read(koreanHistoryProvider.notifier).update((state) {
            if (state.isEmpty) return [_cleanLineStart(transcript)];
            final updated = List<String>.from(state);
            // If the last entry is empty (new-line timer just fired), replace
            // it instead of appending with a space to avoid a leading space.
            updated.last = updated.last.isEmpty
                ? _cleanLineStart(transcript)
                : '${updated.last} $transcript';
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

          // Schedule paragraph break if the current line has too many
          // sentences. Uses a 1s deferred timer (same mechanism as the 2s
          // silence timer) so late-arriving translations land on the
          // correct line before the break fires.
          final lastLine = ref.read(koreanHistoryProvider).lastOrNull ?? '';
          if (_countSentences(lastLine) >=
                  AppConstants.maxParagraphSentences &&
              _sentenceBreakTimer == null) {
            _newLineTimer?.cancel();
            _sentenceBreakTimer = Timer(
              const Duration(seconds: 1),
              () {
                _sentenceBreakTimer = null;
                _newLineTimer?.cancel();
                ref.read(koreanHistoryProvider.notifier).update(
                      (state) => [...state, ''],
                    );
                _newLineTimerTranslation?.cancel();
                _translationNewLinePending = true;
                ref.read(vietnameseHistoryProvider.notifier).update(
                      (state) => [...state, ''],
                    );
                _wordTimestampsPerLine.add([]);
              },
            );
          } else if (_sentenceBreakTimer == null) {
            _newLineTimer = Timer(
              const Duration(milliseconds: AppConstants.newLinePauseMs),
              () {
                ref.read(koreanHistoryProvider.notifier).update(
                      (state) => [...state, ''],
                    );
                // Keep translation panel in sync — new paragraph break for both
                _newLineTimerTranslation?.cancel();
                _translationNewLinePending = true;
                ref.read(vietnameseHistoryProvider.notifier).update(
                      (state) => [...state, ''],
                    );
                _wordTimestampsPerLine.add([]);
              },
            );
          }
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
        _ttsDraftTimer = Timer(const Duration(seconds: 1), () {
          final currentDraft = ref.read(vietnameseDraftProvider);
          if (currentDraft.isNotEmpty && !_ttsFiredForSegment) {
            _ttsFiredForSegment = true;
            _ttsService.speak(currentDraft);
          }
        });
      }
    };

    _sonioxService.onTranslationCompleted = (translation) {
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
            return translation.isNotEmpty
                ? [_cleanLineStart(translation)]
                : state;
          }
          final updated = List<String>.from(state);
          for (int i = 0; i < updated.length; i++) {
            if (updated[i].isEmpty) {
              updated[i] =
                  translation.isNotEmpty ? _cleanLineStart(translation) : ' ';
              return updated;
            }
          }
          // No empty slot — add as new entry
          if (translation.isNotEmpty) {
            return [...updated, _cleanLineStart(translation)];
          }
          return updated;
        });
      } else if (translation.isNotEmpty) {
        // Split mode: append to the current paragraph line.
        // If a paragraph break ('') was already pushed, insert before it
        // so late-arriving translations stay with their paragraph.
        ref.read(vietnameseHistoryProvider.notifier).update((state) {
          if (state.isEmpty) return [_cleanLineStart(translation)];
          final updated = List<String>.from(state);
          if (_translationNewLinePending && updated.last.isEmpty) {
            // New paragraph — replace the '' placeholder (mirrors transcription)
            _translationNewLinePending = false;
            updated.last = _cleanLineStart(translation);
          } else if (updated.last.isEmpty && updated.length >= 2) {
            // Late-arriving translation — append to the line before the break
            final i = updated.length - 2;
            updated[i] = updated[i].isEmpty
                ? _cleanLineStart(translation)
                : '${updated[i]} $translation';
          } else if (updated.last.isEmpty) {
            // Single paragraph break — insert translation before it
            updated.insert(
                updated.length - 1, _cleanLineStart(translation));
          } else {
            // No paragraph break — append to last line
            updated.last = '${updated.last} $translation';
          }
          return updated;
        });
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
      await UserService.instance.ensureAuthenticated();
      _sonioxService.userId = UserService.instance.userId;
      _sonioxService.authToken = UserService.instance.authToken;
      _sonioxService.isPrivateUser = _isPrivateUser;
      await _sonioxService.connect(
        targetLanguageCode: isTranscriptionOnly ? null : targetLanguage.code,
        forceTranslation:
            !isTranscriptionOnly && targetLanguage == TargetLanguage.korean,
        languageHint: isTranscriptionOnly
            ? ''
            : (targetLanguage == TargetLanguage.korean ? '' : null),
      );
      await _audioService.start();
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
      // Start periodic autosave (every 15 seconds)
      _sessionCreatedAt ??= DateTime.now().toIso8601String();
      _autosaveTimer?.cancel();
      _autosaveTimer =
          Timer.periodic(const Duration(seconds: 15), (_) => _autosave());
      _recordingStartedAt = DateTime.now();
      _startUsageLimitTimer();
      UserService.instance.reportActivity('recording_start', {
        'mode': ref.read(displayModeProvider).name,
      });
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
    _sentenceBreakTimer?.cancel();
    _sentenceBreakTimer = null;
    _ttsDraftTimer?.cancel();
    _ttsFiredForSegment = false;
    _usageLimitTimer?.cancel();

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

    // Report recording duration
    if (_recordingStartedAt != null) {
      final durationSecs =
          DateTime.now().difference(_recordingStartedAt!).inSeconds;
      UserService.instance.reportActivity('recording_stop', {
        'duration_seconds': durationSecs,
        'mode': ref.read(displayModeProvider).name,
      });
      // Update local usage estimate immediately
      _usedSeconds += durationSecs;
      _recordingStartedAt = null;
      // Refresh from server (fire-and-forget)
      _fetchUsage();
    }

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

    // Get next session number for default title
    final sessionCount = await DatabaseService.instance.getSessionCount();
    final defaultTitle = 'Session ${sessionCount + 1}';

    if (!mounted) return;

    // Show title input dialog
    final titleController = TextEditingController(text: defaultTitle);
    var firstTap = true;
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Name This Session'),
          content: TextField(
            controller: titleController,
            autofocus: false,
            decoration: const InputDecoration(
              hintText: 'Enter session name',
            ),
            onTap: () {
              if (firstTap) {
                firstTap = false;
                Future.delayed(Duration.zero, () {
                  titleController.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: titleController.text.length,
                  );
                });
              }
            },
            onSubmitted: (_) => Navigator.pop(ctx, titleController.text.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, titleController.text.trim()),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );

    final sessionTitle =
        (title != null && title.isNotEmpty) ? title : defaultTitle;

    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    _sentenceBreakTimer?.cancel();
    _sentenceBreakTimer = null;
    final rawKoreanHistory = ref.read(koreanHistoryProvider);
    final rawVietnameseHistory = ref.read(vietnameseHistoryProvider);

    final koreanHistory =
        rawKoreanHistory.where((s) => s.trim().isNotEmpty).toList();
    final vietnameseHistory =
        rawVietnameseHistory.where((s) => s.trim().isNotEmpty).toList();

    if (koreanHistory.isEmpty && vietnameseHistory.isEmpty) return;

    final koreanFull = koreanHistory.join('\n');
    final vietnameseFull = vietnameseHistory.join('\n');

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
      title: sessionTitle,
    );

    try {
      final id = await DatabaseService.instance.insertSession(session);
      ref.invalidate(sessionHistoryProvider);
      _audioService.clearRecording();
      // Upload to server (fire-and-forget)
      SyncService.instance.uploadSession(session);
      UserService.instance.reportActivity('session_save', {
        'mode': ref.read(displayModeProvider).name,
        'transcription_length': koreanFull.length,
        'translation_length': vietnameseFull.length,
      });
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

  Future<void> _checkForUpdate() async {
    final update = await UpdateService.checkForUpdate();
    if (update == null || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: !update.forceUpdate,
      builder: (context) => PopScope(
        canPop: !update.forceUpdate,
        child: AlertDialog(
          title: const Text('Update Available'),
          content: Text(
            'A new version (${update.latestVersion}) is available. '
            'Please update for the best experience.',
          ),
          actions: [
            if (!update.forceUpdate)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Later'),
              ),
            TextButton(
              onPressed: () async {
                final url = Uri.parse(update.updateUrl);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
              },
              child: const Text('Update'),
            ),
          ],
        ),
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

  Future<void> _restoreSavedLanguages() async {
    final targetLang = await loadSavedTargetLanguage();
    ref.read(targetLanguageProvider.notifier).state = targetLang;
    final convLangs = await loadSavedConversationLanguages();
    ref.read(myLanguageProvider.notifier).state = convLangs.my;
    ref.read(theirLanguageProvider.notifier).state = convLangs.their;
    final displayMode = await loadSavedDisplayMode();
    ref.read(displayModeProvider.notifier).state = displayMode;
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

  Future<void> _startConversationRecording() async {
    // If already recording, ignore (both buttons do the same thing)
    if (ref.read(recordingStateProvider) == RecordingState.recording) return;

    // Check usage limit before starting
    if (_usageLimitReached) {
      _forceStopForUsageLimit();
      return;
    }

    final needsPermission = Platform.isAndroid || Platform.isIOS;
    final status = needsPermission
        ? await Permission.microphone.request()
        : PermissionStatus.granted;
    if (!status.isGranted) return;

    ref.read(activeConversationSpeakerProvider.notifier).state =
        ConversationSpeaker.bottom;
    ref.read(conversationDraftOriginalProvider.notifier).state = '';
    ref.read(conversationDraftTranslatedProvider.notifier).state = '';

    final myLang = ref.read(myLanguageProvider);
    final theirLang = ref.read(theirLanguageProvider);

    // Set up Soniox callbacks for conversation mode
    _sonioxService.onTranscriptionDraft = (draft) {
      ref.read(conversationDraftOriginalProvider.notifier).state = draft;
    };

    _sonioxService.onTranscriptionCompleted = (transcript) {
      if (transcript.isNotEmpty) {
        // Use the current detected speaker (set by onLanguageDetected)
        final currentSpeaker = ref.read(activeConversationSpeakerProvider) ??
            ConversationSpeaker.bottom;
        final msg = ConversationMessage(
          speaker: currentSpeaker,
          originalText: _cleanLineStart(transcript),
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

    _sonioxService.onTranslationCompleted = (translation) {
      if (translation.isNotEmpty) {
        final currentSpeaker = ref.read(activeConversationSpeakerProvider) ??
            ConversationSpeaker.bottom;
        ref.read(conversationMessagesProvider.notifier).update((state) {
          final updated = List<ConversationMessage>.from(state);
          for (int i = updated.length - 1; i >= 0; i--) {
            if (updated[i].speaker == currentSpeaker &&
                updated[i].translatedText.isEmpty) {
              updated[i] = updated[i]
                  .copyWith(translatedText: _cleanLineStart(translation));
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
      // Route speech to correct side based on detected language
      if (language == myLang.code) {
        ref.read(activeConversationSpeakerProvider.notifier).state =
            ConversationSpeaker.bottom;
      } else if (language == theirLang.code) {
        ref.read(activeConversationSpeakerProvider.notifier).state =
            ConversationSpeaker.top;
      }
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
      await UserService.instance.ensureAuthenticated();
      _sonioxService.userId = UserService.instance.userId;
      _sonioxService.authToken = UserService.instance.authToken;
      _sonioxService.isPrivateUser = _isPrivateUser;
      await _sonioxService.connect(
        twoWayLanguageCodes: [myLang.code, theirLang.code],
      );
      await _audioService.start();
      _recordingStartedAt = DateTime.now();
      _startUsageLimitTimer();
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
      UserService.instance.reportActivity('recording_start', {
        'mode': 'conversation',
      });
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
    _usageLimitTimer?.cancel();

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

    if (_recordingStartedAt != null) {
      final durationSecs =
          DateTime.now().difference(_recordingStartedAt!).inSeconds;
      UserService.instance.reportActivity('recording_stop', {
        'duration_seconds': durationSecs,
        'mode': 'conversation',
      });
      _usedSeconds += durationSecs;
      _recordingStartedAt = null;
      _fetchUsage();
    }

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
    saveConversationLanguages(theirLang, myLang);
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
                      saveDisplayMode(mode);
                    },
                    offset: const Offset(0, 40),
                    itemBuilder: (context) {
                      final current = ref.read(displayModeProvider);
                      // Usage stats for the popup
                      final usedMin = _usedSeconds ~/ 60;
                      final pct = _limitMinutes > 0
                          ? ((usedMin / _limitMinutes) * 100)
                              .clamp(0, 100)
                              .round()
                          : 0;
                      return [
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
                          value: DisplayMode.transcription,
                          child: Row(
                            children: [
                              const Expanded(child: Text('Transcription')),
                              if (current == DisplayMode.transcription)
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
                        const PopupMenuDivider(),
                        PopupMenuItem<DisplayMode>(
                          value: current, // keep current mode unchanged
                          onTap: () {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _showPurchasePage();
                            });
                          },
                          child: SizedBox(
                            width: 200,
                            child: _isPrivate
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF2C2C2E),
                                          Color(0xFF1C1C1E),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: const Color(0xFF48483A),
                                        width: 0.5,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.shield_outlined,
                                          size: 16,
                                          color: Color(0xFFCDB56C),
                                        ),
                                        const SizedBox(width: 8),
                                        const Expanded(
                                          child: Text(
                                            'Private Mode',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFFF5F5F7),
                                              letterSpacing: 0.2,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF48483A),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            '\u221E',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFFCDB56C),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Used: $pct%  [$usedMin/$_limitMinutes min]',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(3),
                                        child: LinearProgressIndicator(
                                          value: _limitMinutes > 0
                                              ? (_usedSeconds /
                                                      (_limitMinutes * 60))
                                                  .clamp(0.0, 1.0)
                                              : 0,
                                          minHeight: 6,
                                          backgroundColor: Colors.grey[300],
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                            pct >= 90
                                                ? Colors.red
                                                : pct >= 70
                                                    ? Colors.orange
                                                    : Colors.green,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Tap to add more time',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey[500],
                                        ),
                                      ),
                                    ],
                                  ),
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
                  draftTranslated:
                      ref.watch(conversationDraftTranslatedProvider),
                  activeSpeaker: ref.watch(activeConversationSpeakerProvider),
                  recordingState: recordingState,
                  myLanguage: ref.watch(myLanguageProvider),
                  theirLanguage: ref.watch(theirLanguageProvider),
                  onBottomMicStart: _startConversationRecording,
                  onBottomMicStop: _stopConversationRecording,
                  onTopMicStart: _startConversationRecording,
                  onTopMicStop: _stopConversationRecording,
                  onSwapLanguages: _swapConversationLanguages,
                  onClear: _clearConversation,
                  onMyLanguageChanged: (lang) {
                    ref.read(myLanguageProvider.notifier).state = lang;
                    saveConversationLanguages(
                        lang, ref.read(theirLanguageProvider));
                  },
                  onTheirLanguageChanged: (lang) {
                    ref.read(theirLanguageProvider.notifier).state = lang;
                    saveConversationLanguages(
                        ref.read(myLanguageProvider), lang);
                  },
                ),
              ),
            ] else ...[
              if (displayMode == DisplayMode.transcription) ...[
                Expanded(
                  child: TranscriptPanel(
                    history: koreanHistory,
                    draft: koreanDraft,
                    label: 'Transcription',
                    showCursor:
                        isRecordingOrProcessing && koreanDraft.isNotEmpty,
                    roundedTop: true,
                  ),
                ),
              ] else if (displayMode == DisplayMode.split) ...[
                Expanded(
                  child: TranscriptPanel(
                    history: koreanHistory,
                    draft: koreanDraft,
                    label: 'Transcription',
                    showCursor:
                        isRecordingOrProcessing && koreanDraft.isNotEmpty,
                    roundedTop: true,
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
                    // Mirror the transcription panel's paragraph-break state:
                    // if the transcription has a trailing empty entry (timer
                    // fired after 4s silence), force the translation draft to
                    // render on a new line too, even if the vietnamese history
                    // hasn't caught up yet.
                    forceDraftStandalone: koreanHistory.isNotEmpty &&
                        koreanHistory.last.trim().isEmpty,
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
                  ),
                ),

              // Bottom Controls Area (only for non-conversation modes)
              Container(
                color: AppConstants.bgColor,
                padding: const EdgeInsets.only(top: 20),
                child: Column(
                  children: [
                    // Language Selector Row (hidden in transcription mode)
                    if (displayMode != DisplayMode.transcription)
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
                              saveTargetLanguage(lang);
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

                    SizedBox(
                        height:
                            displayMode == DisplayMode.transcription ? 16 : 32),

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

class _RedeemCodeSection extends StatefulWidget {
  final void Function(int usedSeconds, int limitMinutes) onRedeemed;

  const _RedeemCodeSection({required this.onRedeemed});

  @override
  State<_RedeemCodeSection> createState() => _RedeemCodeSectionState();
}

class _RedeemCodeSectionState extends State<_RedeemCodeSection> {
  final _controller = TextEditingController();
  String? _error;
  bool _isLoading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final res = await UserService.instance.redeemCode(code);
    if (!mounted) return;
    if (res['success'] == true) {
      widget.onRedeemed(res['usedSeconds'] as int, res['limitMinutes'] as int);
    } else {
      setState(() {
        _isLoading = false;
        _error = res['error'] as String?;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: 'Enter private code',
              errorText: _error,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onSubmitted: (_) => _redeem(),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 44,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _redeem,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black87,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Redeem'),
          ),
        ),
      ],
    );
  }
}
