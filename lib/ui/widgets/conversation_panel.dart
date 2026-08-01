import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectionStatus;
import 'package:flutter/services.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/recording_provider.dart';
import '../../providers/target_language_provider.dart';
import '../../utils/constants.dart';
import '../../utils/text_direction_utils.dart';
import 'listening_indicator.dart';

/// Color scheme for the two halves. The top (their side) keeps its teal
/// identity in both themes; the bottom (my side) follows the app palette and
/// inverts its bubbles in dark mode.
class _ConvColors {
  // Top half (their side) — teal theme
  static const topBg = Color(0xFF2BBBAD);
  static const topLangBox = Color(0xFF4DD4C6);
  static const topText = Colors.white;
  static const topMySpeechBubble = Color(0x40FFFFFF);
  static const topTheirSpeechBubble = Colors.white;
  static const topMySpeechText = Colors.white;
  static const topTheirSpeechText = Color(0xFF111111);

  // Bottom half (my side) — panel-toned
  static Color get bottomBg => AppConstants.panelColor;
  static Color get bottomLangBox => AppConstants.panelColor;
  static Color get bottomMySpeechBubble =>
      AppConstants.isDark ? const Color(0xFFE5E5EA) : const Color(0xFF111111);
  static Color get bottomTheirSpeechBubble =>
      AppConstants.isDark ? const Color(0xFF38383C) : const Color(0xFFF0F0F0);
  static Color get bottomMySpeechText =>
      AppConstants.isDark ? const Color(0xFF111111) : Colors.white;
  static Color get bottomTheirSpeechText =>
      AppConstants.isDark ? const Color(0xFFF2F2F3) : const Color(0xFF111111);
}

class ConversationPanel extends StatefulWidget {
  final List<ConversationMessage> messages;
  final String draftOriginal;
  final String draftTranslated;
  final ConversationSpeaker? activeSpeaker;
  final RecordingState recordingState;

  /// True while the session is connecting (mic tapped, audio not yet streaming).
  final bool connecting;
  final TargetLanguage myLanguage;
  final TargetLanguage theirLanguage;

  /// Starts / stops the shared two-way listening session. Either side's button
  /// toggles it — once on, both people speak in turn and each utterance is
  /// auto-routed by detected language.
  final VoidCallback onToggleListening;
  final VoidCallback onSwapLanguages;
  final VoidCallback onClear;
  final ValueChanged<TargetLanguage> onMyLanguageChanged;
  final ValueChanged<TargetLanguage> onTheirLanguageChanged;

  const ConversationPanel({
    super.key,
    required this.messages,
    required this.draftOriginal,
    required this.draftTranslated,
    required this.activeSpeaker,
    required this.recordingState,
    required this.connecting,
    required this.myLanguage,
    required this.theirLanguage,
    required this.onToggleListening,
    required this.onSwapLanguages,
    required this.onClear,
    required this.onMyLanguageChanged,
    required this.onTheirLanguageChanged,
  });

  @override
  State<ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends State<ConversationPanel> {
  final ScrollController _bottomScrollController = ScrollController();
  final ScrollController _topScrollController = ScrollController();
  bool _bottomUserScrolled = false;
  bool _topUserScrolled = false;
  // Selection state per half, read on demand (geometry-based ground truth)
  // rather than latched from SelectionArea.onSelectionChanged, which only
  // fires for gestures and would stay stale when selected bubbles are
  // removed programmatically (clear / new session).
  final SelectionListenerNotifier _bottomSelectionNotifier =
      SelectionListenerNotifier();
  final SelectionListenerNotifier _topSelectionNotifier =
      SelectionListenerNotifier();
  Timer? _bottomResumeTimer;
  Timer? _topResumeTimer;

  // While a text selection is active in a half, that half's auto-scroll must
  // stay off: a jump mid-drag extends the selection over everything that
  // scrolls past, highlighting the whole list.
  bool _hasActiveSelection(SelectionListenerNotifier notifier) =>
      notifier.registered &&
      notifier.selection.status == SelectionStatus.uncollapsed;
  Timer? _ellipsisTimer;
  int _ellipsisCount = 3;

  @override
  void initState() {
    super.initState();
    _syncEllipsisTimer();
    _bottomScrollController.addListener(_onBottomScroll);
    _topScrollController.addListener(_onTopScroll);
  }

  @override
  void didUpdateWidget(ConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncEllipsisTimer();
    // Auto-scroll when new messages or drafts change
    final contentChanged =
        widget.messages.length != oldWidget.messages.length ||
            widget.draftOriginal != oldWidget.draftOriginal ||
            widget.draftTranslated != oldWidget.draftTranslated;
    if (!contentChanged) return;

    if (!_bottomUserScrolled &&
        !_hasActiveSelection(_bottomSelectionNotifier)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _followNewest(_bottomScrollController,
            duration: const Duration(milliseconds: 100));
      });
    }
    if (!_topUserScrolled && !_hasActiveSelection(_topSelectionNotifier)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _followNewest(_topScrollController,
            duration: const Duration(milliseconds: 100));
      });
    }
  }

  /// Keep a reversed list (offset 0 = newest) pinned to the newest bubble
  /// without a per-token animation storm: while already at the bottom the
  /// offset is 0 and every streaming update would restart a zero-distance
  /// scroll activity ~10x/s — skip those. Big gaps (returning after the
  /// user scrolled far up) jump instead of laying out every bubble the
  /// animation would fly past.
  void _followNewest(ScrollController controller,
      {required Duration duration}) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final gap = position.pixels;
    if (gap < 1.0) return;
    if (gap > position.viewportDimension * 2) {
      controller.jumpTo(0);
    } else {
      controller.animateTo(0, duration: duration, curve: Curves.easeOut);
    }
  }

  // The animated dots only render inside the draft bubble, which exists only
  // while a session is live with a detected speaker. Running the timer outside
  // that window would rebuild every bubble in both halves at 2.5Hz forever —
  // even with the panel fully idle.
  bool get _needsEllipsis => _isRecording && widget.activeSpeaker != null;

  void _syncEllipsisTimer() {
    if (_needsEllipsis && _ellipsisTimer == null) {
      _ellipsisTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (mounted) setState(() => _ellipsisCount = (_ellipsisCount % 3) + 1);
      });
    } else if (!_needsEllipsis && _ellipsisTimer != null) {
      _ellipsisTimer?.cancel();
      _ellipsisTimer = null;
    }
  }

  @override
  void dispose() {
    _ellipsisTimer?.cancel();
    _bottomResumeTimer?.cancel();
    _topResumeTimer?.cancel();
    _bottomScrollController.removeListener(_onBottomScroll);
    _topScrollController.removeListener(_onTopScroll);
    _bottomScrollController.dispose();
    _topScrollController.dispose();
    _bottomSelectionNotifier.dispose();
    _topSelectionNotifier.dispose();
    super.dispose();
  }

  // Reversed ListView: offset 0 = newest (bottom), offset > 0 = scrolled away
  void _onBottomScroll() {
    if (!_bottomScrollController.hasClients) return;
    if (_bottomScrollController.offset > 50) {
      _bottomUserScrolled = true;
      _bottomResumeTimer?.cancel();
      _bottomResumeTimer =
          Timer(const Duration(seconds: 3), _resumeBottomAutoScroll);
    } else {
      _bottomUserScrolled = false;
      _bottomResumeTimer?.cancel();
    }
  }

  void _onTopScroll() {
    if (!_topScrollController.hasClients) return;
    if (_topScrollController.offset > 50) {
      _topUserScrolled = true;
      _topResumeTimer?.cancel();
      _topResumeTimer = Timer(const Duration(seconds: 3), _resumeTopAutoScroll);
    } else {
      _topUserScrolled = false;
      _topResumeTimer?.cancel();
    }
  }

  void _resumeBottomAutoScroll() {
    if (!mounted) return;
    if (_hasActiveSelection(_bottomSelectionNotifier)) {
      // Still selecting — retry later instead of leaving _bottomUserScrolled
      // latched true, which would kill auto-scroll for the session.
      _bottomResumeTimer?.cancel();
      _bottomResumeTimer =
          Timer(const Duration(seconds: 3), _resumeBottomAutoScroll);
      return;
    }
    _bottomUserScrolled = false;
    _followNewest(_bottomScrollController,
        duration: const Duration(milliseconds: 300));
  }

  void _resumeTopAutoScroll() {
    if (!mounted) return;
    if (_hasActiveSelection(_topSelectionNotifier)) {
      // Still selecting — retry later instead of leaving _topUserScrolled
      // latched true, which would kill auto-scroll for the session.
      _topResumeTimer?.cancel();
      _topResumeTimer = Timer(const Duration(seconds: 3), _resumeTopAutoScroll);
      return;
    }
    _topUserScrolled = false;
    _followNewest(_topScrollController,
        duration: const Duration(milliseconds: 300));
  }

  bool get _isRecording =>
      widget.recordingState == RecordingState.recording ||
      widget.recordingState == RecordingState.processing;

  bool get _isProcessing => widget.recordingState == RecordingState.processing;

  String _bottomText(ConversationMessage msg) {
    if (msg.speaker == ConversationSpeaker.bottom) {
      return msg.originalText;
    } else {
      return msg.translatedText;
    }
  }

  String _topText(ConversationMessage msg) {
    if (msg.speaker == ConversationSpeaker.top) {
      return msg.originalText;
    } else {
      return msg.translatedText;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top half — rotated 180° for the other person (teal)
        Expanded(
          child: Transform.rotate(
            angle: math.pi,
            child: _buildTopHalf(),
          ),
        ),

        // Center language bar
        _buildLanguageBar(),

        // Bottom half — normal orientation for me (white)
        Expanded(
          child: _buildBottomHalf(),
        ),
      ],
    );
  }

  Widget _buildLanguageBar() {
    return Container(
      color: AppConstants.bgColor,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Left = my language (bottom), white style
          _buildLanguageSelector(
            language: widget.myLanguage,
            onChanged: widget.onMyLanguageChanged,
            enabled: !_isRecording,
            bgColor: _ConvColors.bottomLangBox,
            textColor: AppConstants.textPrimary,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: GestureDetector(
              onTap: _isRecording ? null : widget.onSwapLanguages,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppConstants.isDark
                      ? (_isRecording
                          ? const Color(0xFF2C2C2F)
                          : const Color(0xFF3A3A3E))
                      : (_isRecording
                          ? Colors.grey.shade300
                          : const Color(0xFFE0E0E0)),
                ),
                child: Icon(
                  Icons.swap_horiz,
                  size: 22,
                  color: _isRecording
                      ? Colors.grey.shade500
                      : AppConstants.textPrimary,
                ),
              ),
            ),
          ),
          // Right = their language (top), teal style
          _buildLanguageSelector(
            language: widget.theirLanguage,
            onChanged: widget.onTheirLanguageChanged,
            enabled: !_isRecording,
            bgColor: _ConvColors.topLangBox,
            textColor: _ConvColors.topText,
          ),
          if (widget.messages.isNotEmpty && !_isRecording)
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: GestureDetector(
                onTap: widget.onClear,
                child: Icon(
                  Icons.delete_outline,
                  size: 22,
                  color: AppConstants.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLanguageSelector({
    required TargetLanguage language,
    required ValueChanged<TargetLanguage> onChanged,
    required bool enabled,
    required Color bgColor,
    required Color textColor,
  }) {
    return PopupMenuButton<TargetLanguage>(
      enabled: enabled,
      onSelected: onChanged,
      offset: const Offset(0, -160),
      itemBuilder: (context) => TargetLanguage.values
          .map(
            (lang) => PopupMenuItem<TargetLanguage>(
              value: lang,
              child: Row(
                children: [
                  Expanded(child: Text(lang.displayName)),
                  if (lang == language) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
        width: AppConstants.langBoxWidth,
        height: AppConstants.langBoxHeight,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(AppConstants.langBoxRadius),
        ),
        alignment: Alignment.center,
        child: Text(
          language.displayName,
          style: TextStyle(
            fontSize: AppConstants.langFontSize,
            color: textColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // ── Top Half (teal, for the other person) ──

  Widget _buildTopHalf() {
    return Container(
      color: _ConvColors.topBg,
      child: Column(
        children: [
          Expanded(
            child: _buildMessageList(
              ConversationSpeaker.top,
              _topScrollController,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16, top: 8),
            child: _buildMicButton(tealTheme: true),
          ),
        ],
      ),
    );
  }

  // ── Bottom Half (white, for me) ──

  Widget _buildBottomHalf() {
    return Container(
      color: _ConvColors.bottomBg,
      child: Column(
        children: [
          Expanded(
            child: _buildMessageList(
              ConversationSpeaker.bottom,
              _bottomScrollController,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16, top: 8),
            child: _buildMicButton(tealTheme: false),
          ),
        ],
      ),
    );
  }

  // ── Message List ──

  Widget _buildMessageList(
    ConversationSpeaker perspective,
    ScrollController scrollController,
  ) {
    // Warm-up window: session is live but nobody has been detected speaking
    // yet — show a pulse (per-side colour) so each half isn't mistaken for a
    // freeze while the stream warms up.
    if (_isRecording &&
        widget.messages.isEmpty &&
        widget.activeSpeaker == null) {
      final isTop = perspective == ConversationSpeaker.top;
      return Center(
        child: ListeningIndicator(
          color: isTop ? Colors.white70 : AppConstants.textSecondary,
        ),
      );
    }

    // Lazily built + reversed ListView: item 0 is the newest entry (the draft
    // bubble when live), so only visible bubbles are constructed instead of
    // every message of the session on each rebuild.
    final messages = widget.messages;
    final hasDraft = _isRecording && widget.activeSpeaker != null;
    final itemCount = messages.length + (hasDraft ? 1 : 0);

    final isTop = perspective == ConversationSpeaker.top;
    return SelectionArea(
      child: SelectionListener(
        selectionNotifier:
            isTop ? _topSelectionNotifier : _bottomSelectionNotifier,
        child: ListView.builder(
          controller: scrollController,
          reverse: true,
          padding: const EdgeInsets.symmetric(
            horizontal: AppConstants.panelPaddingH,
            vertical: 12,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            // reverse:true → index 0 sits at the bottom; map back to
            // chronological order.
            final logical = itemCount - 1 - index;
            if (hasDraft && logical == messages.length) {
              // Draft text mutates as tokens stream in — keep it out of the
              // selection so an active selection can't re-anchor onto text
              // that just changed.
              return SelectionContainer.disabled(
                  child: _buildDraftBubble(perspective));
            }
            return _buildMessageBubble(messages[logical], perspective);
          },
        ),
      ),
    );
  }

  Widget _buildMessageBubble(
      ConversationMessage msg, ConversationSpeaker perspective) {
    final isMine = msg.speaker == perspective;
    final isTop = perspective == ConversationSpeaker.top;
    final text = isTop ? _topText(msg) : _bottomText(msg);

    if (text.isEmpty) return const SizedBox.shrink();

    Color bubbleColor;
    Color textColor;
    if (isTop) {
      bubbleColor = isMine
          ? _ConvColors.topMySpeechBubble
          : _ConvColors.topTheirSpeechBubble;
      textColor =
          isMine ? _ConvColors.topMySpeechText : _ConvColors.topTheirSpeechText;
    } else {
      bubbleColor = isMine
          ? _ConvColors.bottomMySpeechBubble
          : _ConvColors.bottomTheirSpeechBubble;
      textColor = isMine
          ? _ConvColors.bottomMySpeechText
          : _ConvColors.bottomTheirSpeechText;
    }

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft:
                isMine ? const Radius.circular(16) : const Radius.circular(4),
            bottomRight:
                isMine ? const Radius.circular(4) : const Radius.circular(16),
          ),
        ),
        child: Text(
          text,
          textDirection: directionOf(text),
          style: TextStyle(
            fontSize: AppConstants.contentFontSize,
            color: textColor,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildDraftBubble(ConversationSpeaker perspective) {
    final activeSpeaker = widget.activeSpeaker!;
    final isMine = activeSpeaker == perspective;
    final isTop = perspective == ConversationSpeaker.top;
    final dots = '.' * _ellipsisCount;

    String text;
    if (isMine) {
      text = widget.draftOriginal.isNotEmpty ? widget.draftOriginal : '';
    } else {
      text = widget.draftTranslated.isNotEmpty
          ? '${widget.draftTranslated}$dots'
          : (widget.draftOriginal.isNotEmpty ? dots : '');
    }

    if (text.isEmpty) return const SizedBox.shrink();

    Color bubbleColor;
    Color textColor;
    if (isTop) {
      bubbleColor = isMine
          ? _ConvColors.topMySpeechBubble
          : _ConvColors.topTheirSpeechBubble.withOpacity(0.8);
      textColor =
          isMine ? _ConvColors.topMySpeechText : _ConvColors.topTheirSpeechText;
    } else {
      bubbleColor = isMine
          ? _ConvColors.bottomMySpeechBubble.withOpacity(0.7)
          : _ConvColors.bottomTheirSpeechBubble.withOpacity(0.8);
      textColor = isMine
          ? _ConvColors.bottomMySpeechText
          : _ConvColors.bottomTheirSpeechText;
    }

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft:
                isMine ? const Radius.circular(16) : const Radius.circular(4),
            bottomRight:
                isMine ? const Radius.circular(4) : const Radius.circular(16),
          ),
        ),
        child: Text(
          text,
          textDirection: directionOf(text),
          style: TextStyle(
            fontSize: AppConstants.contentFontSize,
            color: textColor,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  // ── Mic Button ──

  /// Single tap-to-toggle control for the shared two-way session. Both sides
  /// render one; tapping either starts or stops listening. While listening,
  /// both people just speak in turn — each utterance is auto-routed to the
  /// correct box by its detected language (no button holding).
  Widget _buildMicButton({required bool tealTheme}) {
    const size = 64.0;
    final hintColor =
        tealTheme ? Colors.white.withOpacity(0.85) : AppConstants.textMuted;
    // The bottom mic pairs its glyph with the theme-inverted micButtonColor
    // surface; the teal side keeps its white-circle/teal-glyph identity.
    final bottomMicIconColor = AppConstants.micIconColor;

    Widget mic;
    String hint;

    if (_isProcessing) {
      // Session is finishing — flushing the last translation/TTS.
      mic = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.red.withOpacity(0.8),
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          ),
        ),
      );
      hint = 'Finishing…';
    } else if (widget.connecting) {
      // Connecting — keep it tappable so the tap can be cancelled before the
      // session goes live.
      mic = GestureDetector(
        onTap: () {
          HapticFeedback.mediumImpact();
          widget.onToggleListening();
        },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: tealTheme ? Colors.white : AppConstants.micButtonColor,
          ),
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(
                    tealTheme ? _ConvColors.topBg : bottomMicIconColor),
              ),
            ),
          ),
        ),
      );
      hint = 'Connecting…';
    } else {
      final listening = _isRecording;
      mic = GestureDetector(
        onTap: () {
          HapticFeedback.mediumImpact();
          widget.onToggleListening();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeInOut,
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: listening
                ? Colors.red
                : (tealTheme ? Colors.white : AppConstants.micButtonColor),
            boxShadow: [
              BoxShadow(
                color: listening
                    ? Colors.red.withOpacity(0.3)
                    : Colors.black.withOpacity(0.15),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            listening ? Icons.stop : Icons.mic,
            size: 28,
            color: listening
                ? Colors.white
                : (tealTheme ? _ConvColors.topBg : bottomMicIconColor),
          ),
        ),
      );
      hint = listening ? 'Listening — tap to stop' : 'Tap to start';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        mic,
        const SizedBox(height: 6),
        // Fixed-height slot so the mic doesn't shift as the hint text changes.
        SizedBox(
          height: 15,
          child: Text(
            hint,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: hintColor,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}
