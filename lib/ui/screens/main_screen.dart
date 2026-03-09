import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../models/transcript_session.dart';
import '../../providers/recording_provider.dart';
import '../../providers/target_language_provider.dart';
import '../../providers/transcript_provider.dart';
import '../../providers/translation_provider.dart';
import '../../providers/session_history_provider.dart';
import '../../providers/display_mode_provider.dart';
import '../../services/audio_service.dart';
import '../../services/soniox_realtime_service.dart';
import '../../services/database_service.dart';
import '../../utils/constants.dart';
import '../widgets/transcript_panel.dart';
import '../widgets/record_button.dart';
import '../widgets/save_discard_row.dart';
import '../widgets/history_sheet.dart';
import '../widgets/status_bar.dart';
import '../widgets/line_by_line_panel.dart';
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
  Timer? _newLineTimer;
  Timer? _newLineTimerTranslation;

  // Session invite state
  Map<String, dynamic>? _outgoingInvite;
  Map<String, dynamic>? _incomingInvite;
  Timer? _incomingPollTimer;
  Timer? _outgoingPollTimer;

  // Suppress repeated error snackbars during reconnection
  DateTime? _lastErrorShown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startIncomingPoll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    _incomingPollTimer?.cancel();
    _outgoingPollTimer?.cancel();
    _audioService.dispose();
    _sonioxService.disconnect();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App came back to foreground — reconnect WebSocket if recording
      final recordingState = ref.read(recordingStateProvider);
      if (recordingState == RecordingState.recording) {
        _sonioxService.ensureConnected();
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

    // Set up Soniox transcription callbacks
    _sonioxService.onTranscriptionDraft = (draft) {
      ref.read(koreanDraftProvider.notifier).state = draft;
    };

    _sonioxService.onTranscriptionCompleted = (transcript) {
      if (transcript.isNotEmpty) {
        _newLineTimer?.cancel();
        final isLineByLine =
            ref.read(displayModeProvider) == DisplayMode.lineByLine;

        if (isLineByLine) {
          // Line-by-line: each Soniox endpoint = one segment.
          // Korean is SOV — meaning is incomplete until the verb arrives
          // at the end. Soniox endpoints fire on ~2s silence, which
          // naturally aligns with Korean sentence boundaries.
          // We always ADD a new entry (never merge with previous).
          ref.read(koreanHistoryProvider.notifier).update(
                (state) => [...state, transcript],
              );
          if (targetLanguage == TargetLanguage.korean) {
            // Korean target: copy transcription directly as translation
            ref.read(vietnameseHistoryProvider.notifier).update(
                  (state) => [...state, transcript],
                );
          } else {
            // Pre-create empty slot — will be filled by onTranslationCompleted
            // which fires immediately after (flushed at source boundary).
            ref.read(vietnameseHistoryProvider.notifier).update(
                  (state) => [...state, ''],
                );
          }
          // No timer needed — segments are endpoint-delimited
        } else {
          // Split mode: append to last line, timer-based new lines
          ref.read(koreanHistoryProvider.notifier).update((state) {
            if (state.isEmpty) return [transcript];
            final updated = List<String>.from(state);
            updated.last = '${updated.last} $transcript';
            return updated;
          });
          if (targetLanguage == TargetLanguage.korean) {
            ref.read(vietnameseHistoryProvider.notifier).update((state) {
              if (state.isEmpty) return [transcript];
              final updated = List<String>.from(state);
              updated.last = '${updated.last} $transcript';
              return updated;
            });
          }
          _newLineTimer = Timer(
            const Duration(milliseconds: AppConstants.newLinePauseMs),
            () {
              ref.read(koreanHistoryProvider.notifier).update(
                    (state) => [...state, ''],
                  );
              if (targetLanguage == TargetLanguage.korean) {
                ref.read(vietnameseHistoryProvider.notifier).update(
                      (state) => [...state, ''],
                    );
              }
            },
          );
        }
      }
      ref.read(koreanDraftProvider.notifier).state = '';
    };

    // Set up Soniox translation callbacks (used when target != Korean)
    _sonioxService.onTranslationDraft = (draft) {
      ref.read(vietnameseDraftProvider.notifier).state = draft;
    };

    _sonioxService.onTranslationCompleted = (translation) {
      if (translation.isNotEmpty) {
        _newLineTimerTranslation?.cancel();
        final isLineByLine =
            ref.read(displayModeProvider) == DisplayMode.lineByLine;

        if (isLineByLine) {
          // Translation is flushed BEFORE the new transcription (swap in
          // Soniox service), so accumulated translation belongs to the
          // PREVIOUS segment. Fill the earliest empty slot (forward search).
          ref.read(vietnameseHistoryProvider.notifier).update((state) {
            if (state.isEmpty) return [translation];
            final updated = List<String>.from(state);
            for (int i = 0; i < updated.length; i++) {
              if (updated[i].isEmpty) {
                updated[i] = translation;
                return updated;
              }
            }
            // No empty slot — add as new entry
            return [...updated, translation];
          });
        } else {
          // Split mode: append to last line
          ref.read(vietnameseHistoryProvider.notifier).update((state) {
            if (state.isEmpty) return [translation];
            final updated = List<String>.from(state);
            updated.last = '${updated.last} $translation';
            return updated;
          });
          _newLineTimerTranslation = Timer(
            const Duration(milliseconds: AppConstants.newLinePauseMs),
            () {
              ref.read(vietnameseHistoryProvider.notifier).update(
                    (state) => [...state, ''],
                  );
            },
          );
        }
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
      await _sonioxService.connect(targetLanguageCode: targetLanguage.code);
      await _audioService.start();
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
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
    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    await _audioService.stop();
    _sonioxService.finalize();
    await _sonioxService.disconnect();
    await BackgroundService.stopRecordingService();
    ref.read(recordingStateProvider.notifier).state =
        RecordingState.postRecording;
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
    final koreanHistory = ref
        .read(koreanHistoryProvider)
        .where((s) => s.trim().isNotEmpty)
        .toList();
    final vietnameseHistory = ref
        .read(vietnameseHistoryProvider)
        .where((s) => s.trim().isNotEmpty)
        .toList();

    if (koreanHistory.isEmpty && vietnameseHistory.isEmpty) return;

    final koreanFull = koreanHistory.join('\n');
    final vietnameseFull = vietnameseHistory.join('\n');

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

  void _resetState() {
    ref.read(recordingStateProvider.notifier).state = RecordingState.idle;
    ref.read(koreanDraftProvider.notifier).state = '';
    ref.read(koreanHistoryProvider.notifier).state = [];
    ref.read(vietnameseDraftProvider.notifier).state = '';
    ref.read(vietnameseHistoryProvider.notifier).state = [];
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

            // Content area: Split or Line-by-Line
            if (displayMode == DisplayMode.split) ...[
              Expanded(
                child: TranscriptPanel(
                  history: koreanHistory,
                  draft: koreanDraft,
                  label: 'Transcription',
                  showCursor: isRecordingOrProcessing && koreanDraft.isNotEmpty,
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
                ),
              ),

            // Bottom Controls Area
            Container(
              color: AppConstants.bgColor,
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                children: [
                  // Language Selector Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: AppConstants.langBoxWidth,
                        height: AppConstants.langBoxHeight,
                        decoration: BoxDecoration(
                          color: AppConstants.panelColor,
                          borderRadius: BorderRadius.circular(
                            AppConstants.langBoxRadius,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Any',
                          style: TextStyle(
                            fontSize: AppConstants.langFontSize,
                            color: AppConstants.textPrimary,
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
                                key: ValueKey('right-check-${isPostRecording}'),
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
        ),
      ),
    );
  }
}
