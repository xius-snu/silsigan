import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/recording_provider.dart';
import '../../providers/target_language_provider.dart';
import '../../utils/constants.dart';

/// Color scheme for the two halves
class _ConvColors {
  // Top half (their side) — teal theme
  static const topBg = Color(0xFF2BBBAD);
  static const topLangBox = Color(0xFF4DD4C6);
  static const topText = Colors.white;
  static const topMySpeechBubble = Color(0x40FFFFFF);
  static const topTheirSpeechBubble = Colors.white;
  static const topMySpeechText = Colors.white;
  static const topTheirSpeechText = Color(0xFF111111);

  // Bottom half (my side) — white theme
  static const bottomBg = Color(0xFFFCFCFC);
  static const bottomLangBox = Color(0xFFFCFCFC);
  static const bottomMySpeechBubble = Color(0xFF111111);
  static const bottomTheirSpeechBubble = Color(0xFFF0F0F0);
  static const bottomMySpeechText = Colors.white;
  static const bottomTheirSpeechText = Color(0xFF111111);
}

class ConversationPanel extends StatefulWidget {
  final List<ConversationMessage> messages;
  final String draftOriginal;
  final String draftTranslated;
  final ConversationSpeaker? activeSpeaker;
  final RecordingState recordingState;
  final TargetLanguage myLanguage;
  final TargetLanguage theirLanguage;
  final VoidCallback onBottomMicStart;
  final VoidCallback onBottomMicStop;
  final VoidCallback onTopMicStart;
  final VoidCallback onTopMicStop;
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
    required this.myLanguage,
    required this.theirLanguage,
    required this.onBottomMicStart,
    required this.onBottomMicStop,
    required this.onTopMicStart,
    required this.onTopMicStop,
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
  Timer? _bottomResumeTimer;
  Timer? _topResumeTimer;
  Timer? _ellipsisTimer;
  int _ellipsisCount = 3;

  @override
  void initState() {
    super.initState();
    _startEllipsisTimer();
    _bottomScrollController.addListener(_onBottomScroll);
    _topScrollController.addListener(_onTopScroll);
  }

  @override
  void didUpdateWidget(ConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-scroll when new messages or drafts change
    final contentChanged =
        widget.messages.length != oldWidget.messages.length ||
            widget.draftOriginal != oldWidget.draftOriginal ||
            widget.draftTranslated != oldWidget.draftTranslated;
    if (!contentChanged) return;

    if (!_bottomUserScrolled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_bottomScrollController.hasClients) {
          _bottomScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
    if (!_topUserScrolled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_topScrollController.hasClients) {
          _topScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _startEllipsisTimer() {
    _ellipsisTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() => _ellipsisCount = (_ellipsisCount % 3) + 1);
    });
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
    _bottomUserScrolled = false;
    if (_bottomScrollController.hasClients) {
      _bottomScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _resumeTopAutoScroll() {
    if (!mounted) return;
    _topUserScrolled = false;
    if (_topScrollController.hasClients) {
      _topScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
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
                  color: _isRecording
                      ? Colors.grey.shade300
                      : const Color(0xFFE0E0E0),
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
                child: const Icon(
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
            child: _buildMicButton(
              isActive: _isRecording,
              isDisabled: _isProcessing,
              onStart: widget.onTopMicStart,
              onStop: widget.onTopMicStop,
              tealTheme: true,
            ),
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
            child: _buildMicButton(
              isActive: _isRecording,
              isDisabled: _isProcessing,
              onStart: widget.onBottomMicStart,
              onStop: widget.onBottomMicStop,
              tealTheme: false,
            ),
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
    // Build items in normal order, then reverse for the reversed ListView
    final items = <Widget>[
      for (final msg in widget.messages) _buildMessageBubble(msg, perspective),
      if (_isRecording && widget.activeSpeaker != null)
        _buildDraftBubble(perspective),
    ];
    final reversed = items.reversed.toList();

    return SelectionArea(
      child: ListView(
        controller: scrollController,
        reverse: true,
        padding: const EdgeInsets.symmetric(
          horizontal: AppConstants.panelPaddingH,
          vertical: 12,
        ),
        children: reversed,
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

  Widget _buildMicButton({
    required bool isActive,
    required bool isDisabled,
    required VoidCallback onStart,
    required VoidCallback onStop,
    required bool tealTheme,
  }) {
    const size = 64.0;

    if (isDisabled) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color:
              tealTheme ? Colors.white.withOpacity(0.2) : Colors.grey.shade300,
        ),
        child: Icon(
          Icons.mic_off,
          size: 28,
          color:
              tealTheme ? Colors.white.withOpacity(0.4) : Colors.grey.shade500,
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        if (isActive) {
          onStop();
        } else {
          onStart();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeInOut,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive
              ? Colors.red
              : (tealTheme ? Colors.white : AppConstants.micButtonColor),
          boxShadow: [
            BoxShadow(
              color: isActive
                  ? Colors.red.withOpacity(0.3)
                  : Colors.black.withOpacity(0.15),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          isActive ? Icons.stop_rounded : Icons.mic,
          size: 28,
          color: isActive
              ? Colors.white
              : (tealTheme ? _ConvColors.topBg : Colors.white),
        ),
      ),
    );
  }
}
