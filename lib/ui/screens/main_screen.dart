import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../providers/diarization_provider.dart';
import '../../services/audio_service.dart';
import '../../services/soniox_realtime_service.dart';
import '../../services/database_service.dart';
import '../../services/tts_service.dart';
import '../../providers/tts_provider.dart';
import '../../utils/constants.dart';
import '../widgets/transcript_panel.dart';
import '../widgets/record_button.dart';
import '../widgets/save_discard_row.dart';
import '../widgets/history_sheet.dart';
import '../widgets/status_bar.dart';
import '../widgets/line_by_line_panel.dart';
import '../widgets/split_view_tip_overlay.dart';
import '../widgets/conversation_panel.dart';
import '../widgets/quick_panel.dart';
import '../widgets/source_language_selector.dart';
import '../widgets/tts_control_button.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/quick_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/desktop_audio_source_provider.dart';
import '../../services/user_service.dart';
import '../../services/account_service.dart';
import '../../providers/account_provider.dart';
import '../../services/sync_service.dart';
import '../../services/background_service.dart';
import '../../services/update_service.dart';
import '../../services/purchase_service.dart';
import '../../utils/desktop.dart';
import '../widgets/desktop_audio_source_button.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

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

/// Isolate entry for autosave serialization (see `_autosave`). [args] is
/// `[koreanHistory, vietnameseHistory, wordTimestampsPerLine]`; returns the
/// three JSON strings in the same order.
List<String> _encodeAutosaveDraft(List<Object> args) {
  final koreanHistory = args[0] as List<String>;
  final vietnameseHistory = args[1] as List<String>;
  final timestamps = args[2] as List<List<WordTimestamp>>;
  return [
    jsonEncode(koreanHistory),
    jsonEncode(vietnameseHistory),
    jsonEncode(
      timestamps.map((line) => line.map((w) => w.toJson()).toList()).toList(),
    ),
  ];
}

/// Isolate entry for autosave restore (see `_restoreAutosaveDraft`) — the
/// inverse of [_encodeAutosaveDraft]. [args] is the three JSON strings from
/// the draft row (`korean_history`, `vietnamese_history`, `word_timestamps`,
/// the last nullable); returns `[koreanHistory, vietnameseHistory,
/// wordTimestampsPerLine]`. An hour-long draft is a multi-MB payload with
/// tens of thousands of word timestamps — decoded on the UI isolate it
/// blocked the first frames of every relaunch until the draft was
/// saved or discarded.
List<Object> _decodeAutosaveDraft(List<String?> args) {
  final koreanHistory = (jsonDecode(args[0]!) as List).cast<String>();
  final vietnameseHistory = (jsonDecode(args[1]!) as List).cast<String>();
  final timestamps = <List<WordTimestamp>>[];
  final tsJson = args[2];
  if (tsJson != null) {
    for (final line in jsonDecode(tsJson) as List) {
      timestamps.add(
        (line as List)
            .map((w) => WordTimestamp.fromJson(w as Map<String, dynamic>))
            .toList(),
      );
    }
  }
  return [koreanHistory, vietnameseHistory, timestamps];
}

/// Isolate entry for session-save serialization (see `_saveSession`). [args]
/// is `[rawKoreanHistory, wordTimestampsPerLine]`; returns the timestamps
/// JSON with one entry per non-empty history line (index-aligned with the
/// saved lines, mirroring how the raw history is filtered on save).
String _encodeSessionTimestamps(List<Object> args) {
  final rawKoreanHistory = args[0] as List<String>;
  final timestamps = args[1] as List<List<WordTimestamp>>;
  final tsPerLine = <List<Map<String, dynamic>>>[];
  for (int i = 0; i < rawKoreanHistory.length; i++) {
    if (rawKoreanHistory[i].trim().isEmpty) continue;
    final words =
        i < timestamps.length ? timestamps[i] : const <WordTimestamp>[];
    tsPerLine.add(words.map((w) => w.toJson()).toList());
  }
  return jsonEncode(tsPerLine);
}

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with WidgetsBindingObserver {
  final AudioService _audioService = AudioService();
  // Path of a WAV already produced during a save attempt whose DB insert then
  // failed. Reused on retry so the audio isn't regenerated from a temp PCM
  // that saveRecordingAsWav has already consumed (which would lose it).
  String? _pendingSaveAudioPath;
  final SonioxRealtimeService _sonioxService = SonioxRealtimeService();
  final TtsService _ttsService = TtsService();
  Timer? _newLineTimer;
  Timer? _newLineTimerTranslation;
  Timer? _sentenceBreakTimer;
  bool _translationNewLinePending = false;

  // Auto-TTS: fire TTS on draft text if source endpoint is slow
  Timer? _ttsDraftTimer;
  bool _ttsFiredForSegment = false;

  // Word timestamps per transcription line (for saved sessions)
  final List<List<WordTimestamp>> _wordTimestampsPerLine = [];

  // Guard against multiple stop taps
  bool _isStopping = false;

  // First-time Split View coach-mark, shown after the first non-empty
  // line-by-line stop on iOS/Android. Anchored to the settings gear.
  final GlobalKey _settingsMenuKey = GlobalKey();
  OverlayEntry? _splitViewTipOverlay;
  DisplayMode? _recordingModeForTip;

  // Single-flights _startRecording (the button doesn't flip to Stop until the
  // mic is live, so a rapid second tap would otherwise run a duplicate start
  // chain whose failure path tears down the first chain's session) and locks
  // the diarization toggle until recordingState flips to recording — a toggle
  // tap landing in the startup window flips the icon but is silently ignored
  // for the whole session.
  bool _isStartingRecording = false;

  // ── Quick Mode (press-and-hold) state ──────────────────────────────
  // Confirmed (endpoint-completed) text accumulated during the current hold.
  String _quickTranscriptConfirmed = '';
  String _quickTranslationConfirmed = '';
  // When true, the next transcribed word clears the previous hold's display.
  bool _quickResetPending = false;
  // True between mic press and release.
  bool _quickHolding = false;
  // True while the async start handler is still running its fast setup
  // (permission/auth/mic) — the proxy handshake itself runs in the
  // background (optimistic start).
  bool _quickStarting = false;
  // Resolves when the optimistic (unawaited) connect finishes its handshake
  // attempt. The release path awaits it before finalizeAndWait — a fast
  // press-release would otherwise finalize a not-yet-open socket and drop
  // the speech buffered during the handshake.
  Future<void>? _quickConnectFuture;
  // Language swap state, shared by Quick Mode's swap button and the tappable
  // arrow in line-by-line / split modes. When swapped, a second press restores
  // these snapshots; otherwise it computes a fresh swap. Source/target live in
  // global providers, so the swap is a single source of truth across modes.
  bool _langSwapped = false;
  TargetLanguage? _preSwapSource;
  TargetLanguage _preSwapTarget = TargetLanguage.vietnamese;
  // Most-recently-used target languages (most recent first) — fallback for the
  // swap button when the reply language can't be inferred from the transcript.
  List<TargetLanguage> _recentTargets = [];

  // ── Conversation Mode (two-way toggle) state ───────────────────────
  // Desired session state: set true on start-tap, false on stop-tap. Lets a
  // stop-tap that lands mid-connect cancel the session once it finishes.
  bool _convWantActive = false;
  // True while the async start handler is still running its fast setup
  // (permission/auth/mic) — the proxy handshake itself runs in the
  // background (optimistic start).
  bool _convStarting = false;
  // Resolves when the optimistic (unawaited) connect finishes its handshake
  // attempt. The stop path awaits it so speech buffered mid-handshake gets
  // flushed into the live socket and finalized instead of dropped.
  Future<void>? _convConnectFuture;
  // A translation that completed before its originating utterance's message
  // existed (can happen on the final flush at disconnect, where translation is
  // emitted before transcription). Keyed by speaker; drained when the matching
  // original lands so the pairing survives the ordering.
  final Map<ConversationSpeaker, String> _convPendingTranslation = {};

  // Suppress repeated error snackbars during reconnection
  DateTime? _lastErrorShown;

  // Transient "copied" state for the customer-ID row in the purchase sheet.
  bool _idCopiedInSheet = false;
  String? _restoreFeedbackInSheet;

  // Autosave: periodic timer + session start timestamp
  Timer? _autosaveTimer;
  String? _sessionCreatedAt;
  // Cheap content fingerprint of the last successful autosave — lets the
  // periodic timer skip the (session-sized) re-encode + DB write when
  // nothing changed since the previous save.
  String? _lastAutosaveFingerprint;

  // Analytics: track recording duration
  DateTime? _recordingStartedAt;

  // Track whether app actually went to paused (background), so we only
  // restart audio after a real suspension — not after Control Center, etc.
  bool _wasPaused = false;

  // Usage limit tracking — server-authoritative. The proxy bills audio bytes
  // and force-closes the WS with 4005 when the user crosses their limit;
  // the client trusts that signal rather than running its own timer.
  int _usedSeconds = 0;
  int _limitMinutes = 30;
  static const _isPrivateMode =
      String.fromEnvironment('SONIOX_PRIVATE') == 'true';
  bool _isPrivateUser = false;
  bool get _isPrivate => _isPrivateMode || _isPrivateUser;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ttsService.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
        );
      }
    };
    // Native capture failures after start (record path reports them async on
    // its state stream — the engine tears itself down permanently on the
    // first bad read, e.g. after an audioserver restart, while the UI still
    // shows a live session). Heal in place when possible; stop + notify
    // only when recovery fails.
    _audioService.onCaptureError = (error) {
      if (!mounted) return;
      _handleCaptureFailure();
    };
    // Server-authoritative limit: the proxy closes the WS with 4005 when the
    // user crosses their billed limit. Stop the recording and surface it.
    _sonioxService.onUsageLimitReached = () {
      _forceStopForUsageLimit();
    };
    // Signing in or out repoints usage, purchases and cloud history at a
    // different server row. The change can also arrive unprompted — the
    // once-per-install restore probe lands a second or two after launch — so
    // the screen follows the service rather than only the sheet's buttons.
    AccountService.instance.stateListenable.addListener(_onAccountChanged);
    // Restore saved languages and autosaved draft
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreSavedLanguages();
      _restoreAutosaveDraft();
      _checkForUpdate();
      _fetchUsage();
      PurchaseService.instance.init();
    });
  }

  void _onAccountChanged() {
    if (!mounted) return;
    ref.read(accountProvider.notifier).state = AccountService.instance.state;
    _fetchUsage(force: true);
    ref.invalidate(sessionHistoryProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AccountService.instance.stateListenable.removeListener(_onAccountChanged);
    _newLineTimer?.cancel();
    _newLineTimerTranslation?.cancel();
    _sentenceBreakTimer?.cancel();
    _ttsDraftTimer?.cancel();
    _autosaveTimer?.cancel();
    _dismissSplitViewTip(markSeen: false);
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
    }
    // AppLifecycleState.inactive intentionally does nothing: it fires for
    // transient overlays (Control Center, permission dialogs, the app-switcher
    // animation) and is always followed by `paused` when the app actually
    // backgrounds — autosaving here serialized the whole session a second
    // time at the exact moment the user swipes away. The 15s periodic
    // autosave covers crash recovery while foregrounded.
  }

  /// Restart both WebSocket and audio capture after returning from background.
  /// On iOS (no foreground service), the OS kills audio and network when
  /// suspended — so we must restart both, not just the WebSocket.
  Future<void> _resumeRecording() async {
    try {
      await _sonioxService.ensureConnected();
    } catch (_) {}
    // On Android the foreground service keeps capture alive in the
    // background — restarting the recorder here costs a native stop/start
    // round trip on the resume frame and drops audio during the gap. Only
    // restart when capture actually died (iOS suspension; OEM kills).
    if (_audioService.isCapturingHealthy) return;
    try {
      // Restart audio capture (appends to existing temp PCM file). The
      // timeout is a safety net for a wedged audio HAL after an OEM mic
      // kill — without it a stalled native stop/start would hang this
      // resume chain forever.
      await _startAudioCapture().timeout(_audioStartTimeout);
    } on TimeoutException {
      // .timeout() doesn't cancel the underlying start — a merely-slow
      // restart often still succeeds moments later, so re-check before
      // reporting a failure the user would see while audio is in fact live.
      Future.delayed(const Duration(seconds: 3), () {
        if (!mounted || _audioService.isCapturingHealthy) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to resume microphone')),
        );
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resume microphone: $e')),
        );
      }
    }
  }

  // Capture-failure recovery: one restart in flight at a time, at most two
  // attempts per minute so a hard-dead mic can't loop restarts forever.
  bool _captureRestartInFlight = false;
  DateTime? _captureRestartWindowStart;
  int _captureRestartAttempts = 0;

  /// A native capture error arrived on the recorder's state stream. The
  /// record engine tears itself down permanently on the first bad read
  /// (e.g. ERROR_DEAD_OBJECT after an audioserver restart), so without
  /// intervention the session keeps looking live while recording silence
  /// until the next background/resume cycle. Restart capture in place when
  /// possible; otherwise end the session cleanly so the save/discard UI
  /// appears instead of a dead "recording" screen.
  Future<void> _handleCaptureFailure() async {
    if (_captureRestartInFlight) return;
    // Errors after the session ended (or during teardown) are stale.
    if (!_audioService.isRecording) return;

    final now = DateTime.now();
    if (_captureRestartWindowStart == null ||
        now.difference(_captureRestartWindowStart!) >
            const Duration(seconds: 60)) {
      _captureRestartWindowStart = now;
      _captureRestartAttempts = 0;
    }

    if (_captureRestartAttempts < 2) {
      _captureRestartAttempts++;
      _captureRestartInFlight = true;
      try {
        // Give a spurious error 2s to disprove itself — if data is still
        // flowing, the recorder survived and a restart would only cut it.
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted || !_audioService.isRecording) return;
        if (_audioService.isCapturingHealthy) return;
        // Same restart the resume path uses: appends to the existing temp
        // PCM, and the bounded stop inside start() clears the dead native
        // recorder (which never answers a plain stop).
        await _startAudioCapture().timeout(_audioStartTimeout);
        return; // recovered — the session continues seamlessly
      } catch (_) {
        // fall through to stop + notify
      } finally {
        _captureRestartInFlight = false;
      }
    }

    if (!mounted || !_audioService.isRecording) return;
    // Recovery failed or attempts exhausted: end the session through the
    // normal per-mode stop so the state machine reaches postRecording with
    // everything captured so far, instead of claiming to record silence.
    if (ref.read(recordingStateProvider) == RecordingState.recording) {
      final displayMode = ref.read(displayModeProvider);
      if (displayMode == DisplayMode.conversation) {
        await _stopConversationSession();
      } else if (displayMode == DisplayMode.quick) {
        await _stopQuickRecording();
      } else {
        await _stopRecording();
      }
    }
    if (!mounted) return;
    final shownAt = DateTime.now();
    if (_lastErrorShown == null ||
        shownAt.difference(_lastErrorShown!).inSeconds >= 10) {
      _lastErrorShown = shownAt;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone error — recording stopped')),
      );
    }
  }

  // ── Usage Limit ─────────────��──────────────────────────────────

  /// [force] accepts the server figure even when it is lower than what we hold
  /// locally. Required after an account sign-in or sign-out: the reading now
  /// comes from a different `users` row entirely, so the monotonic guard below
  /// would otherwise pin a stale balance from the previous identity.
  Future<void> _fetchUsage({bool force = false}) async {
    if (_isPrivateMode) return; // compile-time private skips fetch entirely
    final usage = await UserService.instance.fetchUsage();
    if (usage != null && mounted) {
      setState(() {
        // Only accept server value if >= local (avoids race where
        // _fetchUsage returns before reportActivity is processed)
        final serverUsed = usage['usedSeconds'] as int;
        if (force || serverUsed >= _usedSeconds) {
          _usedSeconds = serverUsed;
        }
        _limitMinutes = usage['limitMinutes'] as int;
        _isPrivateUser = usage['isPrivate'] as bool;
      });
    }
  }

  /// Write [value] only when it differs from the provider's current value.
  /// StateProvider notifies on every assignment (identity, not equality), and
  /// Soniox re-sends unchanged draft hypotheses several times a second — each
  /// redundant notification rebuilt the visible panel for nothing.
  void _setIfChanged<T>(StateProvider<T> provider, T value) {
    if (ref.read(provider) != value) {
      ref.read(provider.notifier).state = value;
    }
  }

  int get _remainingSeconds {
    final remaining = _limitMinutes * 60 - _usedSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  bool get _usageLimitReached => !_isPrivate && _remainingSeconds <= 0;

  Future<void> _forceStopForUsageLimit() async {
    final recordingState = ref.read(recordingStateProvider);
    if (recordingState == RecordingState.recording) {
      final displayMode = ref.read(displayModeProvider);
      if (displayMode == DisplayMode.conversation) {
        await _stopConversationSession();
      } else if (displayMode == DisplayMode.quick) {
        await _stopQuickRecording();
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

  /// Metadata for each RevenueCat package identifier.
  static const _packageMeta = {
    'hours_1': {'label': '1 Hour', 'hours': 1},
    'hours_5': {'label': '5 Hours', 'hours': 5, 'discount': '25% OFF'},
    'hours_10': {
      'label': '10 Hours',
      'hours': 10,
      'discount': '40% OFF',
      'badge': 'POPULAR',
    },
    'hours_30': {
      'label': '30 Hours',
      'hours': 30,
      'discount': '50% OFF',
      'badge': 'SAVE 50%',
    },
    'hours_50': {
      'label': '50 Hours',
      'hours': 50,
      'discount': '50% OFF',
      'badge': 'BEST VALUE',
    },
  };

  Future<void> _showPurchasePage() async {
    final purchaseService = PurchaseService.instance;
    if (!purchaseService.isInitialized) {
      await purchaseService.init();
    }
    await purchaseService.refreshOfferings();
    final rcPackages = purchaseService.availablePackages;

    if (!mounted) return;
    _idCopiedInSheet = false;
    _restoreFeedbackInSheet = null;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        // Modal sheets sit outside the scaffold SafeArea. Android's 3-button
        // nav / gesture inset covers the Privacy Policy row unless we lift
        // this padding; iOS's home indicator doesn't collide the same way
        // (the existing 32px is enough). viewPadding stays correct if a
        // keyboard is up, unlike padding.bottom which is consumed.
        final navInset = Platform.isAndroid ? media.viewPadding.bottom : 0.0;
        return Container(
          constraints: BoxConstraints(
            maxHeight: media.size.height - media.viewPadding.top - 12,
          ),
          decoration: BoxDecoration(
            color: AppConstants.sheetColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(
            bottom: media.viewInsets.bottom + navInset,
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
                      color: AppConstants.textFaint,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Add More Time',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'Select a package to add more time',
                  style: TextStyle(fontSize: 14, color: AppConstants.textMuted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),

                // Customer ID (the account's stable code) with tap-to-copy —
                // lets a user quote it in support/purchase enquiries. Feedback
                // is inline (icon flips to a check) because a SnackBar renders
                // in the Scaffold BEHIND this modal sheet and wouldn't be seen.
                Center(
                  child: StatefulBuilder(
                    builder: (idCtx, setIdState) {
                      var copied = _idCopiedInSheet;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final id = UserService.instance.friendCode;
                          if (id == null) return;
                          Clipboard.setData(ClipboardData(text: id));
                          HapticFeedback.selectionClick();
                          setIdState(() => _idCopiedInSheet = true);
                          Timer(const Duration(milliseconds: 1500), () {
                            _idCopiedInSheet = false;
                            if (idCtx.mounted) setIdState(() {});
                          });
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'ID: ${UserService.instance.friendCode ?? '—'}',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.6,
                                color: AppConstants.textMuted,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Icon(
                              copied ? Icons.check : Icons.copy,
                              size: 13,
                              color: copied
                                  ? const Color(0xFF4CAF50)
                                  : AppConstants.textMuted,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),

                // Package cards — same RevenueCat offering on iOS and Android
                if (rcPackages.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      PurchaseService.isSupported
                          ? 'Unable to load packages. Please try again later.'
                          : 'In-app purchases are not available on Windows. '
                              'Use the iOS or Android app, or quote your ID '
                              'above for help with your account.',
                      style: TextStyle(
                          fontSize: 14, color: AppConstants.textMuted),
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  ...rcPackages.map((pkg) => _buildRcPackageCard(ctx, pkg)),

                if (PurchaseService.isSupported) ...[
                  const SizedBox(height: 24),

                  // Restore purchases — snackbars land on the Scaffold behind
                  // this sheet, so confirmation is inline (same as customer ID).
                  StatefulBuilder(
                    builder: (restoreCtx, setRestoreState) {
                      return Column(
                        children: [
                          Center(
                            child: GestureDetector(
                              onTap: () async {
                                final ok =
                                    await PurchaseService.instance.restore();
                                setRestoreState(() {
                                  _restoreFeedbackInSheet = ok
                                      ? 'Purchases restored'
                                      : 'Nothing to restore';
                                });
                              },
                              child: Text(
                                'Restore Purchases',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppConstants.textMuted,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ),
                          if (_restoreFeedbackInSheet != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _restoreFeedbackInSheet!,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppConstants.textMuted,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],

                const SizedBox(height: 12),

                // Privacy Policy & Terms of Service
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: () => launchUrl(
                        Uri.parse(AppConstants.privacyPolicyUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: Text(
                        'Privacy Policy',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppConstants.textFaint,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '|',
                        style: TextStyle(
                            fontSize: 12, color: AppConstants.textFaint),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => launchUrl(
                        Uri.parse(
                          Platform.isIOS
                              ? AppConstants.appleEulaUrl
                              : AppConstants.termsOfUseUrl,
                        ),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: Text(
                        'Terms of Use',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppConstants.textFaint,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Run a RevenueCat purchase behind a blocking "Processing…" overlay. The
  /// StoreKit sheet has its own UI, but after the user confirms there's a
  /// server-credit + usage-refresh window where the bottom sheet is already
  /// gone and the minutes aren't credited yet — without this the user would
  /// stare at the home screen with no feedback. The overlay is always torn
  /// down in the finally, including on cancel/error.
  Future<void> _purchaseRcPackage(
    BuildContext sheetCtx,
    Package rcPkg,
    String label,
  ) async {
    Navigator.pop(sheetCtx); // close the purchase sheet

    BuildContext? overlayCtx;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (dCtx) {
        overlayCtx = dCtx;
        return Center(
          child: Card(
            color: AppConstants.sheetColor,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Processing…',
                    style: TextStyle(
                        fontSize: 14, color: AppConstants.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    int? minutes;
    try {
      minutes = await PurchaseService.instance.purchase(rcPkg);
      if (minutes != null && mounted) {
        // Refresh usage from server
        final usage = await UserService.instance.fetchUsage();
        if (usage != null) {
          setState(() {
            _usedSeconds = usage['usedSeconds'] as int;
            _limitMinutes = usage['limitMinutes'] as int;
          });
        }
      }
    } finally {
      // Always tear down the overlay — confirm, cancel, or error.
      if (overlayCtx != null && overlayCtx!.mounted) {
        Navigator.of(overlayCtx!).pop();
      }
    }

    if (minutes != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label added!')),
      );
    }
  }

  Widget _buildRcPackageCard(BuildContext ctx, Package rcPkg) {
    final meta = _packageMeta[rcPkg.identifier] ??
        {'label': rcPkg.identifier, 'hours': 0};
    final label = meta['label'] as String;
    final hours = meta['hours'] as int;
    final badge = meta['badge'] as String?;
    final discount = meta['discount'] as String?;
    final hasBadge = badge != null;
    final hasDiscount = discount != null;
    final price = rcPkg.storeProduct.priceString;
    final priceNum = rcPkg.storeProduct.price;
    final perHour = hours > 0
        ? '${rcPkg.storeProduct.currencyCode} ${(priceNum / hours).toStringAsFixed(2)}/hr'
        : '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _purchaseRcPackage(ctx, rcPkg, label),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: hasBadge
                ? AppConstants.cardHighlightColor
                : AppConstants.cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hasBadge
                  ? AppConstants.cardHighlightBorderColor
                  : AppConstants.cardBorderColor,
              width: hasBadge ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                        if (hasBadge) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2C2C2E),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              badge,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      perHour,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppConstants.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    price,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  if (hasDiscount)
                    Text(
                      discount,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF4CAF50),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Mic is required to start, except speaker-only capture on iOS/desktop
  /// which never opens the microphone. Android playback capture still needs
  /// RECORD_AUDIO. On Android 13+ we also ask for notifications so the
  /// recording foreground service can show its persistent notice.
  /// Notification denial must not block capture.
  Future<PermissionStatus> _requestRecordingPermissions() async {
    final speakerOnly = audioSourceSelectorSupported &&
        ref.read(desktopAudioSettingsProvider).source ==
            DesktopAudioSource.speaker;
    if (speakerOnly && !Platform.isAndroid) {
      return PermissionStatus.granted;
    }
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isWindows)) {
      return PermissionStatus.granted;
    }
    final status = await Permission.microphone.request();
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
    return status;
  }

  Future<void> _startRecording() async {
    if (_isStartingRecording) return;

    // Check usage limit before starting
    if (_usageLimitReached) {
      _forceStopForUsageLimit();
      return;
    }

    // A new or continued recording invalidates any WAV left by a previous save
    // attempt whose DB insert failed — otherwise the next save could silently
    // attach that stale (shorter) audio to the continued session.
    await _cleanupPendingSaveAudio();

    final status = await _requestRecordingPermissions();
    if (!status.isGranted) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Microphone Required'),
            content: const Text(
              'This app needs microphone access to transcribe speech. '
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
      _setIfChanged(koreanDraftProvider, draft);
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
          // Keep the translation column index-aligned: pad it to this line's
          // slot (left '' when the translation lags the endpoint — a late
          // completion fills it) and close older still-empty slots, whose
          // translation window has passed, so the in-place "..." indicator
          // can't linger on a line that will never get one.
          final lineCount = ref.read(koreanHistoryProvider).length;
          ref.read(vietnameseHistoryProvider.notifier).update((state) {
            final updated = List<String>.from(state);
            for (int i = 0; i < updated.length && i < lineCount - 1; i++) {
              if (updated[i].isEmpty) updated[i] = ' ';
            }
            while (updated.length < lineCount) {
              updated.add('');
            }
            return updated;
          });
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
          if (_countSentences(lastLine) >= AppConstants.maxParagraphSentences &&
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

        _recordSpeakerForLastLine();

        // Update context for next rotation with recent transcript
        final history = ref.read(koreanHistoryProvider);
        _sonioxService.contextText =
            history.reversed.take(10).toList().reversed.join(' ');
      }
      ref.read(koreanDraftProvider.notifier).state = '';
    };

    // Set up Soniox translation callbacks (used when target != Korean)
    _sonioxService.onTranslationDraft = (draft) {
      _setIfChanged(vietnameseDraftProvider, draft);

      // Auto-TTS: debounce — if draft text settles for 1.5s without a source
      // endpoint firing, speak it now rather than waiting.
      _ttsDraftTimer?.cancel();
      if (draft.isNotEmpty &&
          !_ttsFiredForSegment &&
          _ttsService.enabled &&
          TtsService.supportsLanguage(targetLanguage.code)) {
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
          TtsService.supportsLanguage(targetLanguage.code)) {
        _ttsService.speak(translation);
      }
      _ttsFiredForSegment = false;

      final isLineByLine =
          ref.read(displayModeProvider) == DisplayMode.lineByLine;

      if (isLineByLine) {
        // Line-by-line: transcript line i owns translation slot i. A normal
        // completion fires at the source endpoint, just BEFORE its transcript
        // is appended, so it targets index = history length; a late completion
        // (Soniox translates sentence by sentence, so trailing sentences flush
        // after the endpoint) belongs to the last appended line. Set-or-merge
        // at the owning index — consuming "the next empty slot" per completion
        // shifted the whole column down whenever one utterance's translation
        // arrived in several bursts.
        final clean = _cleanLineStart(translation);
        if (clean.isNotEmpty) {
          final lineCount = ref.read(koreanHistoryProvider).length;
          final target =
              _sonioxService.lastTranslationWasLate ? lineCount - 1 : lineCount;
          if (target >= 0) {
            ref.read(vietnameseHistoryProvider.notifier).update((state) {
              final updated = List<String>.from(state);
              while (updated.length <= target) {
                updated.add('');
              }
              updated[target] = updated[target].trim().isEmpty
                  ? clean
                  : '${updated[target]} $clean';
              return updated;
            });
          }
        }
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
            updated.insert(updated.length - 1, _cleanLineStart(translation));
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
        SnackBar(content: Text(error)),
      );
    };

    // Set up audio callback
    _audioService.onAudioChunk = (bytes) {
      _sonioxService.sendAudio(bytes);
    };

    try {
      // Locks the diarization toggle and blocks re-entry from here on; every
      // exit from the try (success or catch) clears it.
      setState(() => _isStartingRecording = true);
      // Start foreground service first (Android) to prevent OS killing the app
      await BackgroundService.startRecordingService();
      await UserService.instance.ensureAuthenticated();
      _sonioxService.userId = UserService.instance.userId;
      _sonioxService.authToken = UserService.instance.authToken;
      _sonioxService.isPrivateUser = _isPrivateUser;
      // Source language: null ("Any") → no hint (pure auto-detect); a pinned
      // language → hint it. forceTranslation keeps the translation config for
      // every non-transcription target (incl. source==target echo cases).
      final sourceLang = ref.read(sourceLanguageProvider);
      // Line-by-line pairs each endpoint 1:1, so hold the endpoint until a
      // fuller/sentence boundary — otherwise mid-sentence fragments get
      // translated without their subject. Other modes keep neutral defaults.
      final isLineByLine =
          ref.read(displayModeProvider) == DisplayMode.lineByLine;
      // Optimistic start: connect() is deliberately NOT awaited — awaiting it
      // held the button on "idle" for a full proxy handshake (DNS + TCP + TLS
      // + WS upgrade ≈ 4 RTTs, ~1s+ far from the proxy). The call still runs
      // synchronously through its audio-buffer clear and kicks off the
      // handshake before its first await; only then is the mic started below,
      // so speech captured while the handshake is in flight lands AFTER the
      // clear in the service's 30s buffer and is flushed only into a
      // proven-live socket. A failed handshake falls into the same
      // reconnect/backoff machinery as a mid-session drop, and a stop tap in
      // the window is honored by the _intentionallyClosed check before the
      // channel is adopted.
      unawaited(_sonioxService.connect(
        targetLanguageCode: isTranscriptionOnly ? null : targetLanguage.code,
        forceTranslation: !isTranscriptionOnly,
        languageHint: sourceLang?.code ?? '',
        enableSpeakerDiarization: ref.read(diarizationEnabledProvider),
        maxEndpointDelayMs:
            isLineByLine ? AppConstants.lineByLineEndpointDelayMs : null,
        endpointSensitivity:
            isLineByLine ? AppConstants.lineByLineEndpointSensitivity : null,
        endpointLatencyAdjustmentLevel: isLineByLine
            ? AppConstants.lineByLineEndpointLatencyAdjustmentLevel
            : null,
      ));
      await _startAudioCapture();
      // The recording state now holds the toggle gate; the flag must clear
      // here or the toggle would stay dimmed after the session ends.
      _isStartingRecording = false;
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
      // Start periodic autosave (every 15 seconds)
      _sessionCreatedAt ??= DateTime.now().toIso8601String();
      _autosaveTimer?.cancel();
      _autosaveTimer =
          Timer.periodic(const Duration(seconds: 15), (_) => _autosave());
      _recordingStartedAt = DateTime.now();
      final startedMode = ref.read(displayModeProvider);
      _recordingModeForTip = startedMode;
      if (startedMode == DisplayMode.split) {
        unawaited(markHasRecordedSplit());
      }
      _dismissSplitViewTip(markSeen: false);
      UserService.instance.reportActivity('recording_start', {
        'mode': startedMode.name,
      });
    } catch (e) {
      _isStartingRecording = false;
      // The unawaited connect may already be live (or mid-handshake) — tear
      // it down so a failed mic start can't leak a connected, rotating
      // session with no audio source.
      try {
        await _sonioxService.disconnect().timeout(const Duration(seconds: 3));
      } catch (_) {}
      await BackgroundService.stopRecordingService();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: $e')),
        );
      }
    }
  }

  /// Attribute the just-completed utterance's speaker to the transcript line
  /// it landed on. Padded with nulls up to the history length so restored
  /// autosave lines (which carry no speaker data) never shift attribution.
  /// A split-mode paragraph keeps the first speaker attributed to it — a
  /// label that's already on screen shouldn't flip retroactively.
  void _recordSpeakerForLastLine() {
    final speaker = _sonioxService.lastCompletedSpeaker;
    final historyLen = ref.read(koreanHistoryProvider).length;
    if (historyLen == 0) return;
    ref.read(speakerHistoryProvider.notifier).update((state) {
      final updated = List<int?>.from(state);
      while (updated.length < historyLen) {
        updated.add(null);
      }
      if (speaker != null && updated[historyLen - 1] == null) {
        updated[historyLen - 1] = speaker;
      }
      return updated;
    });
  }

  void _onDiarizationChanged(bool enabled) {
    ref.read(diarizationEnabledProvider.notifier).state = enabled;
    saveDiarizationEnabled(enabled);
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
      _maybeShowSplitViewTip();
    }
  }

  void _dismissSplitViewTip({bool markSeen = true}) {
    final wasShowing = _splitViewTipOverlay != null;
    _splitViewTipOverlay?.remove();
    _splitViewTipOverlay = null;
    if (markSeen && wasShowing) {
      unawaited(markSplitViewTipSeen());
    }
  }

  /// After a line-by-line stop, show a one-shot coach-mark pointing at the
  /// settings gear. Skipped on desktop, empty sessions, and anyone who has
  /// already dismissed it, switched to Split View, or recorded in split.
  void _maybeShowSplitViewTip() {
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    if (_recordingModeForTip != DisplayMode.lineByLine) return;
    if (ref.read(displayModeProvider) != DisplayMode.lineByLine) return;

    Future<void>.delayed(const Duration(milliseconds: 400), () async {
      if (!mounted || _splitViewTipOverlay != null) return;
      if (ref.read(recordingStateProvider) != RecordingState.postRecording) {
        return;
      }
      if (ref.read(displayModeProvider) != DisplayMode.lineByLine) return;
      final hasLines =
          ref.read(koreanHistoryProvider).any((l) => l.trim().isNotEmpty);
      if (!hasLines) return;
      if (await hasSeenSplitViewTip()) return;
      if (!mounted) return;
      _insertSplitViewTip();
    });
  }

  void _insertSplitViewTip() {
    if (_splitViewTipOverlay != null) return;
    final box =
        _settingsMenuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final origin = box.localToGlobal(Offset.zero);
    final target = origin & box.size;

    _splitViewTipOverlay = OverlayEntry(
      builder: (ctx) => SplitViewTipOverlay(
        targetRect: target,
        onDismiss: () => _dismissSplitViewTip(),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_splitViewTipOverlay!);
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

    // Serialize word timestamps (per-line, aligned with raw history) off the
    // UI isolate — an hour of speech is tens of thousands of timestamps, and
    // encoding them inline froze the frame on the save tap.
    String? timestampsJson;
    if (_wordTimestampsPerLine.isNotEmpty) {
      timestampsJson = await compute(_encodeSessionTimestamps, <Object>[
        rawKoreanHistory,
        List<List<WordTimestamp>>.from(_wordTimestampsPerLine),
      ]);
    }

    // Save audio file if available. Reuse a WAV already produced by a prior
    // failed save attempt so a retry never regenerates from a temp PCM that
    // saveRecordingAsWav has already consumed (which would silently lose it).
    String? audioPath = _pendingSaveAudioPath;
    if (audioPath == null && _audioService.hasRecording) {
      try {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        audioPath =
            await _audioService.saveRecordingAsWav('session_$timestamp.wav');
        _pendingSaveAudioPath = audioPath;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Could not save audio — try again'),
              action: SnackBarAction(label: 'Retry', onPressed: _saveSession),
            ),
          );
        }
        return;
      }
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
      _pendingSaveAudioPath = null; // WAV now owned by the saved session

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
    await _cleanupPendingSaveAudio();
    _audioService.clearRecording();
    _resetState();
  }

  /// Delete a WAV left behind by a save attempt that never committed to the DB.
  Future<void> _cleanupPendingSaveAudio() async {
    final path = _pendingSaveAudioPath;
    _pendingSaveAudioPath = null;
    if (path == null) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
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
      builder: (_) => HistorySheet(
        maxFraction: sheetFraction,
        onAccountSheetClosed: () => _fetchUsage(force: true),
      ),
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
        onAccountSheetClosed: () => _fetchUsage(force: true),
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

  Duration get _audioStartTimeout {
    final speaker = ref.read(desktopAudioSettingsProvider).captureSpeaker;
    if (speaker && isMobileSpeakerCapture) {
      return const Duration(seconds: 90);
    }
    return const Duration(seconds: 8);
  }

  Future<void> _startAudioCapture() {
    return _audioService.start(
      desktop: audioSourceSelectorSupported
          ? ref.read(desktopAudioSettingsProvider)
          : null,
    );
  }

  void _toggleDarkMode() {
    HapticFeedback.selectionClick();
    final next = !ref.read(darkModeProvider);
    ref.read(darkModeProvider.notifier).state = next;
    saveDarkMode(next);
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

    // Skip when nothing changed since the last successful save — covers
    // silent stretches between 15s ticks and back-to-back lifecycle saves.
    final fingerprint = _draftFingerprint(koreanHistory, vietnameseHistory);
    if (fingerprint == _lastAutosaveFingerprint) return;

    _sessionCreatedAt ??= DateTime.now().toIso8601String();

    // Shallow snapshot so the isolate copy below can't interleave with a
    // concurrent line append (inner lists are never mutated once stored).
    final timestamps = List<List<WordTimestamp>>.from(_wordTimestampsPerLine);

    try {
      // The payload grows with the session (every line + every word
      // timestamp) — encode it off the UI isolate so a long session doesn't
      // jank a frame on every save.
      final encoded = await compute(
        _encodeAutosaveDraft,
        [koreanHistory, vietnameseHistory, timestamps],
      );
      await DatabaseService.instance.saveAutosaveDraft({
        'korean_history': encoded[0],
        'vietnamese_history': encoded[1],
        'word_timestamps': encoded[2],
        'target_language': ref.read(targetLanguageProvider).code,
        'created_at': _sessionCreatedAt!,
        'updated_at': DateTime.now().toIso8601String(),
      });
      _lastAutosaveFingerprint = fingerprint;
    } catch (_) {
      // Silently ignore autosave failures — don't disrupt the user
    }
  }

  /// Cheap content fingerprint for autosave skipping. Lengths + last entries
  /// catch appends and last-entry rewrites; the summed text sizes catch the
  /// split-mode late-translation write into a middle slot (which changes
  /// neither lengths nor tails but always grows a slot); the target language
  /// is included because the draft persists it too.
  String _draftFingerprint(
      List<String> koreanHistory, List<String> vietnameseHistory) {
    final koreanChars = koreanHistory.fold<int>(0, (n, s) => n + s.length);
    final vietnameseChars =
        vietnameseHistory.fold<int>(0, (n, s) => n + s.length);
    return '${koreanHistory.length}:${vietnameseHistory.length}:'
        '$koreanChars:$vietnameseChars:'
        '${ref.read(targetLanguageProvider).code}:'
        '${_wordTimestampsPerLine.length}:'
        '${_wordTimestampsPerLine.isEmpty ? 0 : _wordTimestampsPerLine.last.length} '
        '${koreanHistory.isEmpty ? '' : koreanHistory.last} '
        '${vietnameseHistory.isEmpty ? '' : vietnameseHistory.last}';
  }

  Future<void> _restoreSavedLanguages() async {
    final targetLang = await loadSavedTargetLanguage();
    ref.read(targetLanguageProvider.notifier).state = targetLang;
    final sourceLang = await loadSavedSourceLanguage();
    ref.read(sourceLanguageProvider.notifier).state = sourceLang;
    _recentTargets = await loadRecentTargets();
    final convLangs = await loadSavedConversationLanguages();
    ref.read(myLanguageProvider.notifier).state = convLangs.my;
    ref.read(theirLanguageProvider.notifier).state = convLangs.their;
    final displayMode = await loadSavedDisplayMode();
    ref.read(displayModeProvider.notifier).state = displayMode;
    final ttsRate = await loadSavedTtsRate();
    ref.read(ttsRateProvider.notifier).state = ttsRate;
    final diarization = await loadSavedDiarizationEnabled();
    ref.read(diarizationEnabledProvider.notifier).state = diarization;
    if (audioSourceSelectorSupported) {
      final desktopAudio = await loadSavedDesktopAudioSettings();
      ref.read(desktopAudioSettingsProvider.notifier).state = desktopAudio;
    }
  }

  /// True while any mode's session is live or in its optimistic-start window.
  /// recordingState alone is not enough: it stays `idle` for the whole start
  /// window (the button flips only once the mic is live), so a restore
  /// completing mid-start could clobber the new session's state.
  bool get _sessionActiveOrStarting =>
      ref.read(recordingStateProvider) != RecordingState.idle ||
      _isStartingRecording ||
      _quickStarting ||
      _convStarting;

  Future<void> _restoreAutosaveDraft() async {
    try {
      // Only restore if still idle (user hasn't started recording already)
      if (_sessionActiveOrStarting) return;

      final draft = await DatabaseService.instance.getAutosaveDraft();
      if (draft == null) {
        // No draft to attach recovered audio to — clear any crash leftovers.
        await _audioService.clearOrphanRecordings();
        return;
      }

      // Re-check after async gap — widget may be disposed or user tapped mic
      if (!mounted) return;
      if (_sessionActiveOrStarting) return;

      // Decode off the UI isolate — an hour-long draft carries tens of
      // thousands of word timestamps, and decoding it inline blocked the
      // first frames of every relaunch (mirrors the compute() in _autosave).
      final decoded = await compute(_decodeAutosaveDraft, <String?>[
        draft['korean_history'] as String,
        draft['vietnamese_history'] as String,
        draft['word_timestamps'] as String?,
      ]);
      final koreanHistory = decoded[0] as List<String>;
      final vietnameseHistory = decoded[1] as List<String>;

      // Re-check after async gap — user may have started recording
      if (!mounted) return;
      if (_sessionActiveOrStarting) return;

      // Don't restore empty drafts
      if (koreanHistory.isEmpty && vietnameseHistory.isEmpty) {
        await DatabaseService.instance.clearAutosaveDraft();
        await _audioService.clearOrphanRecordings();
        return;
      }

      ref.read(koreanHistoryProvider.notifier).state = koreanHistory;
      ref.read(vietnameseHistoryProvider.notifier).state = vietnameseHistory;

      // Restore word timestamps
      _wordTimestampsPerLine
        ..clear()
        ..addAll(decoded[2] as List<List<WordTimestamp>>);

      // Restore target language
      final targetCode = draft['target_language'] as String;
      final targetLang = TargetLanguage.values.where(
        (l) => l.code == targetCode,
      );
      if (targetLang.isNotEmpty) {
        ref.read(targetLanguageProvider.notifier).state = targetLang.first;
      }

      // Seed the autosave fingerprint so the first lifecycle-pause autosave
      // after a relaunch doesn't re-encode and rewrite the entire (still
      // unchanged) multi-MB draft it just loaded. Seeded after the draft's
      // target language is applied — the fingerprint includes it.
      _lastAutosaveFingerprint =
          _draftFingerprint(koreanHistory, vietnameseHistory);

      _sessionCreatedAt = draft['created_at'] as String;

      // Set state to postRecording so user sees save/discard buttons
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.postRecording;

      // Recover audio from the crash: the PCM the recorder streamed to disk may
      // still be there. Adopt it so a subsequent Save includes the audio.
      await _audioService.adoptOrphanRecording();

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

  void _setupConversationCallbacks() {
    _sonioxService.onTranscriptionDraft = (draft) {
      // Route the in-progress transcript to whichever side is speaking now,
      // detected live from the source-token language.
      _setConversationSpeaker(
          _speakerForLanguage(_sonioxService.currentSourceLanguage));
      _setIfChanged(conversationDraftOriginalProvider, draft);
    };

    _sonioxService.onTranscriptionCompleted = (transcript) {
      if (transcript.isNotEmpty) {
        final speaker =
            _speakerForLanguage(_sonioxService.lastCompletedSourceLanguage) ??
                ref.read(activeConversationSpeakerProvider) ??
                ConversationSpeaker.bottom;
        // A translation that landed before this original existed (final-flush
        // ordering) was stashed by speaker — attach it now.
        final pending = _convPendingTranslation.remove(speaker) ?? '';
        final msg = ConversationMessage(
          speaker: speaker,
          originalText: _cleanLineStart(transcript),
          translatedText: pending,
        );
        ref.read(conversationMessagesProvider.notifier).update(
              (state) => [...state, msg],
            );
      }
      ref.read(conversationDraftOriginalProvider.notifier).state = '';
    };

    _sonioxService.onTranslationDraft = (draft) {
      _setIfChanged(conversationDraftTranslatedProvider, draft);
    };

    _sonioxService.onTranslationCompleted = (translation) {
      if (translation.isNotEmpty) {
        final clean = _cleanLineStart(translation);
        // The side that SPOKE this utterance — the translation names its own
        // source language, so routing survives the other side already having
        // started the next turn. Fall back to the live source language, then
        // the active side.
        final srcSpeaker = _speakerForLanguage(
                _sonioxService.lastCompletedTranslationSourceLanguage) ??
            _speakerForLanguage(_sonioxService.currentSourceLanguage) ??
            ref.read(activeConversationSpeakerProvider) ??
            ConversationSpeaker.bottom;
        // The side whose utterance is being transcribed RIGHT NOW. At a
        // normal endpoint this equals srcSpeaker; when it differs, the
        // endpoint that triggered this emission belongs to the OTHER side
        // and this text is srcSpeaker's trailing translation (emitted
        // non-late only because the other side's source was pending) — it
        // belongs to srcSpeaker's last message, and stashing it instead
        // would leak it into srcSpeaker's NEXT bubble (the drain is keyed
        // by the transcribed side).
        final liveSpeaker =
            _speakerForLanguage(_sonioxService.currentSourceLanguage);
        final belongsToLastMessage = _sonioxService.lastTranslationWasLate ||
            (liveSpeaker != null && liveSpeaker != srcSpeaker);
        if (belongsToLastMessage) {
          // Trailing sentences of an utterance whose message is already on
          // screen. Merge into this speaker's NEWEST message. Never fill an
          // OLDER untranslated message: its translation window has passed
          // (the service flushes a lagging translation before the next
          // utterance's tokens are processed), and claiming it would shift
          // every later translation one bubble back for the rest of the
          // session — the ordering bug that used to need a stop/restart.
          bool merged = false;
          ref.read(conversationMessagesProvider.notifier).update((state) {
            final updated = List<ConversationMessage>.from(state);
            for (int i = updated.length - 1; i >= 0; i--) {
              if (updated[i].speaker == srcSpeaker) {
                updated[i] = updated[i].copyWith(
                  translatedText: updated[i].translatedText.trim().isEmpty
                      ? clean
                      : '${updated[i].translatedText} $clean',
                );
                merged = true;
                break;
              }
            }
            return updated;
          });
          // No message from this speaker yet — hold it for the first one.
          if (!merged) _stashConvTranslation(srcSpeaker, clean);
        } else {
          // Endpoint completion of srcSpeaker's own utterance — emitted just
          // BEFORE its transcription completes, so it belongs to the message
          // about to be created, not to any bubble already on screen. Stash
          // it; the transcription handler drains it into the new message.
          _stashConvTranslation(srcSpeaker, clean);
        }
        // Voice it in the listener's (opposite side's) language.
        _speakConversationTranslation(srcSpeaker, clean);
      }
      ref.read(conversationDraftTranslatedProvider.notifier).state = '';
    };

    _sonioxService.onLanguageDetected = (language) {
      ref.read(detectedLanguageProvider.notifier).state = language;
      // A new person starting to speak flips the active side; cut any TTS still
      // voicing the previous turn so the device isn't talking over the speaker.
      _setConversationSpeaker(_speakerForLanguage(language), flushTts: true);
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
        SnackBar(content: Text(error)),
      );
    };
  }

  /// Append [text] to the pending-translation stash for [speaker]. A single
  /// utterance can complete in several bursts (Soniox translates sentence by
  /// sentence), so later bursts join earlier ones instead of overwriting them.
  void _stashConvTranslation(ConversationSpeaker speaker, String text) {
    final existing = _convPendingTranslation[speaker];
    _convPendingTranslation[speaker] =
        (existing == null || existing.isEmpty) ? text : '$existing $text';
  }

  /// Set the currently-speaking side. On an actual change, clears stale drafts
  /// so the previous turn's in-progress text/translation doesn't bleed into the
  /// new speaker's boxes, and optionally cuts TTS still voicing the old turn.
  /// A null [speaker] (unrecognized language) leaves the current side unchanged.
  void _setConversationSpeaker(ConversationSpeaker? speaker,
      {bool flushTts = false}) {
    if (speaker == null) return;
    if (ref.read(activeConversationSpeakerProvider) == speaker) return;
    ref.read(activeConversationSpeakerProvider.notifier).state = speaker;
    ref.read(conversationDraftOriginalProvider.notifier).state = '';
    ref.read(conversationDraftTranslatedProvider.notifier).state = '';
    if (flushTts) _ttsService.flush();
  }

  /// Headphone prompt shown before the Conversation speaker is turned on.
  /// Returns true if the user confirms (then TTS is enabled), false otherwise.
  Future<bool> _confirmEnableConversationSpeaker() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use headphones'),
        content: const Text(
          'With the speaker on, each translation is played out loud. Because '
          'both people share one microphone, put on headphones first so it '
          "doesn't pick up the audio and echo.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Maps a Soniox-detected ISO language code to the conversation side that
  /// speaks it, or null when it's neither configured language.
  ConversationSpeaker? _speakerForLanguage(String? code) {
    if (code == null) return null;
    if (code == ref.read(myLanguageProvider).code) {
      return ConversationSpeaker.bottom;
    }
    if (code == ref.read(theirLanguageProvider).code) {
      return ConversationSpeaker.top;
    }
    return null;
  }

  /// Speak a completed translation aloud in the LISTENER's language — the side
  /// opposite [srcSpeaker] — when Conversation TTS is enabled.
  void _speakConversationTranslation(
      ConversationSpeaker srcSpeaker, String text) {
    if (!ref.read(conversationTtsEnabledProvider)) return;
    // If the other side has already taken the floor, this trailing translation
    // would talk over the live speaker — skip voicing it (the text still shows
    // on-screen). Voicing resumes for the next turn.
    final active = ref.read(activeConversationSpeakerProvider);
    if (active != null && active != srcSpeaker) return;
    final myLang = ref.read(myLanguageProvider);
    final theirLang = ref.read(theirLanguageProvider);
    final ttsLangCode =
        srcSpeaker == ConversationSpeaker.bottom ? theirLang.code : myLang.code;
    if (TtsService.supportsLanguage(ttsLangCode)) {
      _ttsService.setLanguageCode(ttsLangCode);
      _ttsService.speak(text);
    }
  }

  /// Tap-to-toggle the shared two-way listening session. Either side's mic
  /// starts it; once on, both people speak in turn with no button holding.
  Future<void> _toggleConversationSession() async {
    if (_convStarting) {
      // Tapped again mid-connect — request cancel; the start handler tears the
      // session down once its connect completes (recordingState is still idle
      // during connect, so this path, not the stop branch, handles the cancel).
      _convWantActive = false;
      return;
    }
    final st = ref.read(recordingStateProvider);
    if (st == RecordingState.processing) return; // busy finishing
    if (st == RecordingState.idle) {
      await _startConversationSession();
    } else {
      await _stopConversationSession();
    }
  }

  Future<void> _startConversationSession() async {
    if (_convStarting) return;
    final st = ref.read(recordingStateProvider);
    if (st == RecordingState.recording || st == RecordingState.processing) {
      return;
    }

    // Check usage limit before starting
    if (_usageLimitReached) {
      _forceStopForUsageLimit();
      return;
    }

    _convWantActive = true;
    _convStarting = true;

    final status = await _requestRecordingPermissions();
    if (!status.isGranted) {
      _convWantActive = false;
      _convStarting = false;
      return;
    }

    // Fresh session: clear stale drafts, stashed translations, and any TTS.
    // Show the connecting affordance so the tap gives immediate feedback.
    ref.read(conversationConnectingProvider.notifier).state = true;
    _ttsService.flush();
    _convPendingTranslation.clear();
    ref.read(activeConversationSpeakerProvider.notifier).state = null;
    ref.read(conversationDraftOriginalProvider.notifier).state = '';
    ref.read(conversationDraftTranslatedProvider.notifier).state = '';

    final myLang = ref.read(myLanguageProvider);
    final theirLang = ref.read(theirLanguageProvider);

    _setupConversationCallbacks();
    _audioService.onAudioChunk = (bytes) => _sonioxService.sendAudio(bytes);

    try {
      await BackgroundService.startRecordingService();
      await UserService.instance.ensureAuthenticated();
      _sonioxService.userId = UserService.instance.userId;
      _sonioxService.authToken = UserService.instance.authToken;
      _sonioxService.isPrivateUser = _isPrivateUser;
      // Optimistic start (same pattern as _startRecording): the handshake is
      // NOT awaited, so the mic goes live immediately and speech captured
      // while the proxy connects buffers in the service (30s cap) and
      // flushes into a proven-live socket. connect() must be invoked before
      // _audioService.start() — it synchronously clears the audio buffer
      // before its first await. A failed handshake falls into the same
      // reconnect/backoff machinery as a mid-session drop.
      _convConnectFuture = _sonioxService.connect(
        twoWayLanguageCodes: [myLang.code, theirLang.code],
      );
      await _startAudioCapture();
      _recordingStartedAt = DateTime.now();
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
      UserService.instance.reportActivity('recording_start', {
        'mode': 'conversation',
      });
    } catch (e) {
      // The unawaited connect may already be live (or mid-handshake) — tear
      // it down so a failed mic start can't leak a connected session with no
      // audio source.
      try {
        await _sonioxService.disconnect().timeout(const Duration(seconds: 3));
      } catch (_) {}
      _convConnectFuture = null;
      await BackgroundService.stopRecordingService();
      _convStarting = false;
      _convWantActive = false;
      ref.read(conversationConnectingProvider.notifier).state = false;
      ref.read(activeConversationSpeakerProvider.notifier).state = null;
      if (mounted) {
        ref.read(recordingStateProvider.notifier).state = RecordingState.idle;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: $e')),
        );
      }
      return;
    }

    _convStarting = false;
    ref.read(conversationConnectingProvider.notifier).state = false;

    // A cancel-tap during the setup window, or a usage-limit 4005 that closed
    // the socket mid-connect, means the session should not stay live — tear
    // it down now.
    if (!_convWantActive || _sonioxService.isClosed) {
      await _stopConversationSession();
    }
  }

  Future<void> _stopConversationSession() async {
    _convWantActive = false;
    ref.read(conversationConnectingProvider.notifier).state = false;

    if (_convStarting) return;
    if (ref.read(recordingStateProvider) != RecordingState.recording) return;
    if (_isStopping) return;
    _isStopping = true;

    ref.read(recordingStateProvider.notifier).state = RecordingState.processing;

    try {
      await _audioService.stop().timeout(const Duration(seconds: 5));
    } catch (_) {}

    // Let an in-flight optimistic handshake land first, so speech buffered
    // during it flushes into the live socket and gets finalized below instead
    // of dying with a never-opened channel.
    final convWasStillConnecting = !_sonioxService.isConnected;
    final convConnect = _convConnectFuture;
    _convConnectFuture = null;
    if (convConnect != null) {
      try {
        await convConnect.timeout(const Duration(seconds: 8));
      } catch (_) {}
    }

    // Finalize, let trailing translation tokens land (each voiced as it lands
    // via onTranslationCompleted), then disconnect. Normally a fixed 700ms
    // grace suffices — but when the stop tap beat the handshake, the whole
    // turn was only just flushed into a cold session (first tokens take
    // ~1-2s incl. model warm-up), so wait token-aware instead of cutting the
    // turn off at a fixed deadline.
    if (convWasStillConnecting) {
      try {
        await _sonioxService.finalizeAndWait(
          quiet: const Duration(seconds: 2),
          timeout: const Duration(seconds: 8),
        );
      } catch (_) {}
    } else {
      try {
        _sonioxService.finalize();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 700));
    }
    try {
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
    _convPendingTranslation.clear();
  }

  void _swapConversationLanguages() {
    final myLang = ref.read(myLanguageProvider);
    final theirLang = ref.read(theirLanguageProvider);
    ref.read(myLanguageProvider.notifier).state = theirLang;
    ref.read(theirLanguageProvider.notifier).state = myLang;
    saveConversationLanguages(theirLang, myLang);
  }

  // ── Quick Mode Recording (press-and-hold) ───────────────────────────

  String _quickJoin(String a, String b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a $b';
  }

  /// Clear the previous hold's display on the first word of a new hold, so the
  /// old translation stays visible until fresh text actually arrives.
  void _maybeQuickReset(String text) {
    if (!_quickResetPending || text.trim().isEmpty) return;
    _quickResetPending = false;
    _quickTranscriptConfirmed = '';
    _quickTranslationConfirmed = '';
    ref.read(quickTranscriptProvider.notifier).state = '';
    ref.read(quickTranslationProvider.notifier).state = '';
  }

  void _setupQuickCallbacks() {
    _sonioxService.onLanguageDetected = (language) {
      ref.read(detectedLanguageProvider.notifier).state = language;
    };

    _sonioxService.onTranscriptionDraft = (draft) {
      _maybeQuickReset(draft);
      _setIfChanged(quickTranscriptProvider,
          _quickJoin(_quickTranscriptConfirmed, draft));
    };

    _sonioxService.onTranscriptionCompleted = (transcript) {
      _maybeQuickReset(transcript);
      final clean = _cleanLineStart(transcript.trim());
      if (clean.isNotEmpty) {
        _quickTranscriptConfirmed =
            _quickJoin(_quickTranscriptConfirmed, clean);
      }
      ref.read(quickTranscriptProvider.notifier).state =
          _quickTranscriptConfirmed;
    };

    _sonioxService.onTranslationDraft = (draft) {
      _setIfChanged(quickTranslationProvider,
          _quickJoin(_quickTranslationConfirmed, draft));
    };

    _sonioxService.onTranslationCompleted = (translation) {
      final clean = _cleanLineStart(translation.trim());
      if (clean.isNotEmpty) {
        _quickTranslationConfirmed =
            _quickJoin(_quickTranslationConfirmed, clean);
      }
      ref.read(quickTranslationProvider.notifier).state =
          _quickTranslationConfirmed;
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
        SnackBar(content: Text(error)),
      );
    };
  }

  Future<void> _startQuickRecording() async {
    if (_quickStarting) return;
    final st = ref.read(recordingStateProvider);
    if (st == RecordingState.recording || st == RecordingState.processing) {
      return;
    }

    // Server-authoritative usage limit (shows paywall if exhausted).
    if (_usageLimitReached) {
      _forceStopForUsageLimit();
      return;
    }

    _quickHolding = true;
    _quickStarting = true;

    final status = await _requestRecordingPermissions();
    if (!status.isGranted) {
      _quickHolding = false;
      _quickStarting = false;
      return;
    }

    // Cut off any translation still being spoken from the previous hold.
    _ttsService.flush();

    // Keep the previous text on screen until the first new word arrives.
    _quickResetPending = true;
    ref.read(detectedLanguageProvider.notifier).state = null;
    _setupQuickCallbacks();
    _audioService.onAudioChunk = (bytes) => _sonioxService.sendAudio(bytes);

    final targetLanguage = ref.read(targetLanguageProvider);
    _recordRecentTarget(targetLanguage);

    try {
      await BackgroundService.startRecordingService();
      await UserService.instance.ensureAuthenticated();
      _sonioxService.userId = UserService.instance.userId;
      _sonioxService.authToken = UserService.instance.authToken;
      _sonioxService.isPrivateUser = _isPrivateUser;
      // Optimistic start (same pattern as _startRecording): the handshake is
      // NOT awaited, so capture begins the moment the press lands and speech
      // spoken while the proxy connects buffers in the service (30s cap) and
      // flushes into a proven-live socket — this is what makes Quick Mode
      // actually quick. connect() must be invoked before
      // _audioService.start() (it synchronously clears the audio buffer
      // before its first await).
      _quickConnectFuture = _sonioxService.connect(
        targetLanguageCode: targetLanguage.code,
        forceTranslation: true,
        languageHint: ref.read(sourceLanguageProvider)?.code ?? '',
      );
      await _startAudioCapture();
      _recordingStartedAt = DateTime.now();
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
      UserService.instance.reportActivity('recording_start', {'mode': 'quick'});
    } catch (e) {
      // The unawaited connect may already be live (or mid-handshake) — tear
      // it down so a failed mic start can't leak a connected session with no
      // audio source.
      try {
        await _sonioxService.disconnect().timeout(const Duration(seconds: 3));
      } catch (_) {}
      _quickConnectFuture = null;
      await BackgroundService.stopRecordingService();
      _quickStarting = false;
      _quickHolding = false;
      if (mounted) {
        ref.read(recordingStateProvider.notifier).state = RecordingState.idle;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: $e')),
        );
      }
      return;
    }

    _quickStarting = false;

    // The user may have released before the setup finished — stop now.
    if (!_quickHolding) {
      await _stopQuickRecording();
    }
  }

  Future<void> _stopQuickRecording() async {
    _quickHolding = false;

    // Start handler is still connecting; it will call us once it finishes.
    if (_quickStarting) return;
    // Nothing to stop unless we're actually recording.
    if (ref.read(recordingStateProvider) != RecordingState.recording) return;
    if (_isStopping) return;
    _isStopping = true;

    ref.read(recordingStateProvider.notifier).state = RecordingState.processing;

    // Stop audio input immediately — no more speech is captured.
    try {
      await _audioService.stop().timeout(const Duration(seconds: 5));
    } catch (_) {}

    // A fast press-release can beat the optimistic handshake. Wait for it so
    // the speech buffered during the connect flushes into the live socket —
    // finalizeAndWait is a silent no-op on an unconnected service, and
    // disconnecting here would drop the whole utterance.
    final quickWasStillConnecting = !_sonioxService.isConnected;
    final quickConnect = _quickConnectFuture;
    _quickConnectFuture = null;
    if (quickConnect != null) {
      try {
        await quickConnect.timeout(const Duration(seconds: 8));
      } catch (_) {}
    }

    // Finalize and WAIT for the trailing translation to actually finish
    // streaming (even though the user already released), then disconnect —
    // which flushes the settled translation into the providers. A fixed delay
    // here would cut off translations that lag the source. When the release
    // beat the handshake, the utterance was only just flushed into a cold
    // session — extend the quiet window past model warm-up (~1-2s) so the
    // settle can't expire before the first token even arrives.
    try {
      await _sonioxService.finalizeAndWait(
        quiet: quickWasStillConnecting
            ? const Duration(seconds: 2)
            : const Duration(milliseconds: 500),
      );
    } catch (_) {}
    try {
      await _sonioxService.disconnect().timeout(const Duration(seconds: 3));
    } catch (_) {}

    try {
      await BackgroundService.stopRecordingService()
          .timeout(const Duration(seconds: 3));
    } catch (_) {}

    _audioService.clearRecording();
    _isStopping = false;

    // Usage reporting (Quick Mode is metered like the other modes).
    if (_recordingStartedAt != null) {
      final durationSecs =
          DateTime.now().difference(_recordingStartedAt!).inSeconds;
      UserService.instance.reportActivity('recording_stop', {
        'duration_seconds': durationSecs,
        'mode': 'quick',
      });
      _usedSeconds += durationSecs;
      _recordingStartedAt = null;
      _fetchUsage();
    }

    // Speak the full translation aloud, unless the user muted Quick Mode's
    // speaker toggle.
    final translation = ref.read(quickTranslationProvider).trim();
    if (ref.read(quickTtsEnabledProvider) &&
        translation.isNotEmpty &&
        TtsService.supportsLanguage(ref.read(targetLanguageProvider).code)) {
      _ttsService.speak(translation);
    }

    if (mounted) {
      ref.read(recordingStateProvider.notifier).state = RecordingState.idle;
    }
  }

  /// Clear Quick Mode's transcription + translation immediately (no confirm)
  /// and stop any speech still playing.
  void _clearQuick() {
    _quickTranscriptConfirmed = '';
    _quickTranslationConfirmed = '';
    _quickResetPending = false;
    ref.read(quickTranscriptProvider.notifier).state = '';
    ref.read(quickTranslationProvider.notifier).state = '';
    ref.read(detectedLanguageProvider.notifier).state = null;
    // The current languages become the new baseline for the swap toggle.
    if (_langSwapped) setState(() => _langSwapped = false);
    _ttsService.flush();
  }

  /// Re-speak the current Quick Mode translation on demand. Uses speakOnce so
  /// it plays even when the speaker toggle is muted (and a second tap stops it).
  void _replayQuick() {
    final translation = ref.read(quickTranslationProvider).trim();
    if (translation.isEmpty) return;
    if (!TtsService.supportsLanguage(ref.read(targetLanguageProvider).code)) {
      return;
    }
    _ttsService.speakOnce(translation);
  }

  /// The [TargetLanguage] whose code matches [code], or null if [code] isn't
  /// one of the supported target languages (unlike [TargetLanguage.fromCode],
  /// which falls back to Vietnamese).
  TargetLanguage? _targetForCode(String? code) {
    if (code == null) return null;
    for (final l in TargetLanguage.values) {
      if (l.code == code) return l;
    }
    return null;
  }

  /// A sensible "other" target language when we can't infer one from the
  /// transcript: the most-recently-used target that differs from [current],
  /// else Vietnamese (or Korean if [current] is already Vietnamese).
  TargetLanguage _fallbackTarget(TargetLanguage current) {
    for (final l in _recentTargets) {
      if (l != current) return l;
    }
    return current == TargetLanguage.vietnamese
        ? TargetLanguage.korean
        : TargetLanguage.vietnamese;
  }

  /// Record [lang] as the most-recently-used target language (deduped, capped).
  void _recordRecentTarget(TargetLanguage lang) {
    _recentTargets
      ..remove(lang)
      ..insert(0, lang);
    if (_recentTargets.length > 5) {
      _recentTargets = _recentTargets.sublist(0, 5);
    }
    saveRecentTargets(_recentTargets);
  }

  /// Whether the current mode has any transcribed content yet — used by the
  /// language swap to decide whether it can infer the reply language from what
  /// was just spoken. Quick Mode keeps a single transcript string; line-by-line
  /// and split keep a history list.
  bool get _hasTranscribedContent {
    if (ref.read(displayModeProvider) == DisplayMode.quick) {
      return ref.read(quickTranscriptProvider).trim().isNotEmpty;
    }
    return ref.read(koreanHistoryProvider).any((l) => l.trim().isNotEmpty);
  }

  /// Language swap. Used by Quick Mode's swap button and the tappable arrow in
  /// line-by-line / split modes. Toggles the target language to the other side
  /// of the conversation so the listener can reply, and restores the original on
  /// a second press. Behavior depends on the current setup:
  ///   • Source pinned (2-way): swap source ↔ target.
  ///   • Source "Any" + transcript: target → the detected transcript language.
  ///   • Source "Any" + empty (or undetectable): target → most-recently-used.
  void _swapLanguages() {
    final currentSource = ref.read(sourceLanguageProvider);
    final currentTarget = ref.read(targetLanguageProvider);

    // Second press: restore the snapshot taken when we swapped.
    if (_langSwapped) {
      ref.read(sourceLanguageProvider.notifier).state = _preSwapSource;
      ref.read(targetLanguageProvider.notifier).state = _preSwapTarget;
      saveSourceLanguage(_preSwapSource);
      saveTargetLanguage(_preSwapTarget);
      setState(() => _langSwapped = false);
      return;
    }

    TargetLanguage? newSource;
    TargetLanguage newTarget;
    if (currentSource != null) {
      // 2-way mode: swap the two pinned languages.
      newSource = currentTarget;
      newTarget = currentSource;
    } else {
      // "Any" source: aim the target at whatever was just spoken so the reply
      // gets translated back. Fall back to a recent language when the transcript
      // is empty, the language is undetectable, or it equals the current target.
      newSource = null;
      final hasTranscript = _hasTranscribedContent;
      TargetLanguage? candidate;
      if (hasTranscript) {
        candidate = _targetForCode(ref.read(detectedLanguageProvider));
      }
      if (candidate == null || candidate == currentTarget) {
        candidate = _fallbackTarget(currentTarget);
      }
      newTarget = candidate;
    }

    // Nothing would change — leave the toggle off so a press isn't a no-op.
    if (newSource == currentSource && newTarget == currentTarget) return;

    _preSwapSource = currentSource;
    _preSwapTarget = currentTarget;
    ref.read(sourceLanguageProvider.notifier).state = newSource;
    ref.read(targetLanguageProvider.notifier).state = newTarget;
    saveSourceLanguage(newSource);
    saveTargetLanguage(newTarget);
    _recordRecentTarget(newTarget);
    setState(() => _langSwapped = true);
  }

  void _resetState() {
    _autosaveTimer?.cancel();
    _sessionCreatedAt = null;
    _lastAutosaveFingerprint = null;
    DatabaseService.instance.clearAutosaveDraft();
    ref.read(recordingStateProvider.notifier).state = RecordingState.idle;
    ref.read(koreanDraftProvider.notifier).state = '';
    ref.read(koreanHistoryProvider.notifier).state = [];
    ref.read(vietnameseDraftProvider.notifier).state = '';
    ref.read(vietnameseHistoryProvider.notifier).state = [];
    ref.read(detectedLanguageProvider.notifier).state = null;
    ref.read(speakerHistoryProvider.notifier).state = [];
    _wordTimestampsPerLine.clear();
    _sonioxService.contextText = null;
    // Fresh session: current languages become the new swap baseline.
    _langSwapped = false;
    _ttsService.stop();
    // Conversation state
    ref.read(conversationMessagesProvider.notifier).state = [];
    ref.read(conversationDraftOriginalProvider.notifier).state = '';
    ref.read(conversationDraftTranslatedProvider.notifier).state = '';
    ref.read(activeConversationSpeakerProvider.notifier).state = null;
    ref.read(conversationConnectingProvider.notifier).state = false;
    _convPendingTranslation.clear();
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: the streaming providers (drafts, histories, speaker history,
    // conversation/quick state) are deliberately NOT watched here — they
    // update several times per second while recording, and watching them at
    // this level rebuilt the entire screen per Soniox token. Each panel
    // below watches what it needs inside its own Consumer.
    final recordingState = ref.watch(recordingStateProvider);
    final targetLanguage = ref.watch(targetLanguageProvider);
    final sourceLanguage = ref.watch(sourceLanguageProvider);
    final displayMode = ref.watch(displayModeProvider);
    final ttsEnabled = ref.watch(ttsEnabledProvider);
    final detectedLanguage = ref.watch(detectedLanguageProvider);
    final diarizationEnabled = ref.watch(diarizationEnabledProvider);
    // Watched so the whole screen rebuilds when the theme toggles — the
    // AppConstants color getters resolve against the flipped palette on the
    // rebuild (SilsiganApp sets AppConstants.isDark before this runs).
    final isDarkMode = ref.watch(darkModeProvider);

    // Sync TTS service state with provider. In Conversation mode the TTS
    // language is chosen per-turn (the listener's side) at release time, so
    // don't overwrite it here.
    if (displayMode != DisplayMode.conversation) {
      _ttsService.setLanguageCode(targetLanguage.code);
    }
    // Quick + Conversation always voice the translation on release; the other
    // modes use the global toggle. Driving setEnabled from the active mode on
    // every build also keeps rebuilds from cutting off in-progress playback.
    final quickTtsEnabled = ref.watch(quickTtsEnabledProvider);
    final bool ttsOn = displayMode == DisplayMode.quick
        ? quickTtsEnabled
        : displayMode == DisplayMode.conversation
            ? ref.watch(conversationTtsEnabledProvider)
            : ttsEnabled;
    _ttsService.setEnabled(ttsOn);
    _ttsService.setRate(ref.watch(ttsRateProvider));

    // Show speaker toggle for languages with TTS support + valid API key
    final showTtsToggle = TtsService.supportsLanguage(targetLanguage.code) &&
        TtsService.hasApiKey;

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
                  Text(
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
                  // Conversation TTS toggle — speak the translation on release.
                  if (displayMode == DisplayMode.conversation) ...[
                    TtsControlButton(
                      enabled: ref.watch(conversationTtsEnabledProvider),
                      onEnabledChanged: (v) => ref
                          .read(conversationTtsEnabledProvider.notifier)
                          .state = v,
                      confirmEnable: _confirmEnableConversationSpeaker,
                      iconSize: 24,
                    ),
                    const SizedBox(width: 16),
                  ],
                  GestureDetector(
                    onTap: _toggleDarkMode,
                    child: Icon(
                      isDarkMode
                          ? Icons.light_mode_outlined
                          : Icons.dark_mode_outlined,
                      size: 24,
                      color: AppConstants.textSecondary,
                    ),
                  ),
                  if (audioSourceSelectorSupported) ...[
                    const SizedBox(width: 16),
                    DesktopAudioSourceButton(
                      enabled: !isRecordingOrProcessing,
                    ),
                  ],
                  const SizedBox(width: 16),
                  PopupMenuButton<DisplayMode>(
                    key: _settingsMenuKey,
                    onOpened: () => _dismissSplitViewTip(),
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
                      String fmtHrMin(int m) => '${m ~/ 60}h ${m % 60}m';
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
                        PopupMenuItem<DisplayMode>(
                          value: DisplayMode.quick,
                          child: Row(
                            children: [
                              const Expanded(child: Text('Quick Mode')),
                              if (current == DisplayMode.quick)
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
                                        'Used: $pct%  [${fmtHrMin(usedMin)}/${fmtHrMin(_limitMinutes)}]',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                          color: AppConstants.textPrimary,
                                        ),
                                        // Long totals (e.g. 100h 30m/200h 30m)
                                        // won't fit the 200px popup on one line —
                                        // wrap to a second line (which shifts the
                                        // bar down) instead of clipping the end.
                                        softWrap: true,
                                        maxLines: 2,
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
                                          backgroundColor: AppConstants.isDark
                                              ? Colors.grey[700]
                                              : Colors.grey[300],
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
                                          color: AppConstants.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ];
                    },
                    child: Icon(
                      Icons.settings_outlined,
                      size: 24,
                      color: AppConstants.textSecondary,
                    ),
                  ),
                ],
              ),
            ),

            // Content area: Quick / Conversation / Split / Line-by-Line
            if (displayMode == DisplayMode.quick) ...[
              Expanded(
                child: Consumer(builder: (context, ref, _) {
                  return QuickPanel(
                    transcript: ref.watch(quickTranscriptProvider),
                    translation: ref.watch(quickTranslationProvider),
                    recordingState: recordingState,
                    targetLanguage: targetLanguage,
                    sourceLanguage: sourceLanguage,
                    detectedLanguage: detectedLanguage,
                    onSourceChanged: (lang) {
                      ref.read(sourceLanguageProvider.notifier).state = lang;
                      saveSourceLanguage(lang);
                      if (_langSwapped) setState(() => _langSwapped = false);
                    },
                    speakerEnabled: quickTtsEnabled,
                    onSpeakerChanged: (v) {
                      ref.read(quickTtsEnabledProvider.notifier).state = v;
                    },
                    onMicPressStart: _startQuickRecording,
                    onMicPressEnd: _stopQuickRecording,
                    onClear: _clearQuick,
                    onReplay: _replayQuick,
                    onTargetLanguageChanged: (lang) {
                      ref.read(targetLanguageProvider.notifier).state = lang;
                      saveTargetLanguage(lang);
                      _recordRecentTarget(lang);
                      if (_langSwapped) setState(() => _langSwapped = false);
                    },
                    swapActive: _langSwapped,
                    onSwap: _swapLanguages,
                  );
                }),
              ),
            ] else if (displayMode == DisplayMode.conversation) ...[
              Expanded(
                child: Consumer(builder: (context, ref, _) {
                  return ConversationPanel(
                    messages: ref.watch(conversationMessagesProvider),
                    draftOriginal: ref.watch(conversationDraftOriginalProvider),
                    draftTranslated:
                        ref.watch(conversationDraftTranslatedProvider),
                    activeSpeaker: ref.watch(activeConversationSpeakerProvider),
                    recordingState: recordingState,
                    connecting: ref.watch(conversationConnectingProvider),
                    myLanguage: ref.watch(myLanguageProvider),
                    theirLanguage: ref.watch(theirLanguageProvider),
                    onToggleListening: _toggleConversationSession,
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
                  );
                }),
              ),
            ] else ...[
              if (displayMode == DisplayMode.transcription) ...[
                Expanded(
                  child: Consumer(builder: (context, ref, _) {
                    final koreanHistory = ref.watch(koreanHistoryProvider);
                    final koreanDraft = ref.watch(koreanDraftProvider);
                    return TranscriptPanel(
                      history: koreanHistory,
                      draft: koreanDraft,
                      label: 'Transcription',
                      showCursor:
                          isRecordingOrProcessing && koreanDraft.isNotEmpty,
                      isRecording: isRecordingOrProcessing,
                      roundedTop: true,
                      speakers: ref.watch(speakerHistoryProvider),
                      showDiarizationToggle: true,
                      diarizationEnabled: diarizationEnabled,
                      onDiarizationChanged: _onDiarizationChanged,
                      diarizationInteractive:
                          !isRecordingOrProcessing && !_isStartingRecording,
                    );
                  }),
                ),
              ] else if (displayMode == DisplayMode.split) ...[
                Expanded(
                  child: Consumer(builder: (context, ref, _) {
                    final koreanHistory = ref.watch(koreanHistoryProvider);
                    final koreanDraft = ref.watch(koreanDraftProvider);
                    return TranscriptPanel(
                      history: koreanHistory,
                      draft: koreanDraft,
                      label: 'Transcription',
                      showCursor:
                          isRecordingOrProcessing && koreanDraft.isNotEmpty,
                      isRecording: isRecordingOrProcessing,
                      roundedTop: true,
                      speakers: ref.watch(speakerHistoryProvider),
                      showDiarizationToggle: true,
                      diarizationEnabled: diarizationEnabled,
                      onDiarizationChanged: _onDiarizationChanged,
                      diarizationInteractive:
                          !isRecordingOrProcessing && !_isStartingRecording,
                    );
                  }),
                ),
                Container(
                  height: 5,
                  color: AppConstants.dividerColor,
                ),
                Expanded(
                  child: Consumer(builder: (context, ref, _) {
                    final koreanHistory = ref.watch(koreanHistoryProvider);
                    final vietnameseHistory =
                        ref.watch(vietnameseHistoryProvider);
                    final vietnameseDraft = ref.watch(vietnameseDraftProvider);
                    return TranscriptPanel(
                      history: vietnameseHistory,
                      draft: vietnameseDraft,
                      label: 'Translation',
                      showEllipsis:
                          isRecordingOrProcessing && vietnameseDraft.isNotEmpty,
                      showSpeakerToggle: showTtsToggle,
                      speakerEnabled: ttsEnabled,
                      onSpeakerToggle: _toggleTts,
                      // Translation paragraphs mirror transcription paragraphs
                      // 1:1, so the same per-paragraph speaker list applies.
                      speakers: ref.watch(speakerHistoryProvider),
                      // Mirror the transcription panel's paragraph-break state:
                      // if the transcription has a trailing empty entry (timer
                      // fired after 4s silence), force the translation draft to
                      // render on a new line too, even if the vietnamese
                      // history hasn't caught up yet.
                      forceDraftStandalone: koreanHistory.isNotEmpty &&
                          koreanHistory.last.trim().isEmpty,
                    );
                  }),
                ),
              ] else
                Expanded(
                  child: Consumer(builder: (context, ref, _) {
                    return LineByLinePanel(
                      transcriptionHistory: ref.watch(koreanHistoryProvider),
                      transcriptionDraft: ref.watch(koreanDraftProvider),
                      translationHistory: ref.watch(vietnameseHistoryProvider),
                      translationDraft: ref.watch(vietnameseDraftProvider),
                      isRecording: isRecordingOrProcessing,
                      showSpeakerToggle: showTtsToggle,
                      speakerEnabled: ttsEnabled,
                      onSpeakerToggle: _toggleTts,
                      onSpeakLine: (text) => _ttsService.speakOnce(text),
                      ttsLineState:
                          showTtsToggle ? _ttsService.lineState : null,
                      speakers: ref.watch(speakerHistoryProvider),
                      showDiarizationToggle: true,
                      diarizationEnabled: diarizationEnabled,
                      onDiarizationChanged: _onDiarizationChanged,
                      diarizationInteractive:
                          !isRecordingOrProcessing && !_isStartingRecording,
                    );
                  }),
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
                          SourceLanguageSelector(
                            source: sourceLanguage,
                            detectedLanguage: detectedLanguage,
                            isRecording: isRecordingOrProcessing,
                            enabled: !isRecordingOrProcessing,
                            onChanged: (lang) {
                              ref.read(sourceLanguageProvider.notifier).state =
                                  lang;
                              saveSourceLanguage(lang);
                              if (_langSwapped) {
                                setState(() => _langSwapped = false);
                              }
                            },
                          ),
                          // Tappable swap arrow: flips source ↔ target (or, with
                          // an "Any" source mid-session, points the target at the
                          // last-detected language so the listener can reply).
                          // A second press reverts. Disabled while recording —
                          // Soniox is configured with the target at connect time.
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: isRecordingOrProcessing
                                ? null
                                : () {
                                    HapticFeedback.selectionClick();
                                    _swapLanguages();
                                  },
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: 40,
                                height: 40,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _langSwapped
                                      ? AppConstants.micButtonColor
                                      : Colors.transparent,
                                ),
                                child: Icon(
                                  _langSwapped
                                      ? Icons.swap_horiz
                                      : Icons.arrow_forward,
                                  size: 27,
                                  color: _langSwapped
                                      ? AppConstants.micIconColor
                                      : AppConstants.textPrimary,
                                ),
                              ),
                            ),
                          ),
                          PopupMenuButton<TargetLanguage>(
                            enabled: !isRecordingOrProcessing,
                            onSelected: (lang) {
                              ref.read(targetLanguageProvider.notifier).state =
                                  lang;
                              saveTargetLanguage(lang);
                              _recordRecentTarget(lang);
                              if (_langSwapped) {
                                setState(() => _langSwapped = false);
                              }
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
                                style: TextStyle(
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
                                  iconColor: isPostRecording
                                      ? AppConstants.saveButtonActiveIconColor
                                      : Colors.white,
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
