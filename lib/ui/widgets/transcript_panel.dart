import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/constants.dart';
import '../../utils/text_direction_utils.dart';
import 'listening_indicator.dart';
import 'tts_control_button.dart';

/// Strip leading whitespace and leading punctuation (+ trailing space) so that
/// a displayed line never visually starts with a space or dangling punctuation.
String _cleanLineStart(String text) {
  text = text.trimLeft();
  return text.replaceFirst(RegExp(r'^[,.\-;:!?、。，；：！？…·]+\s*'), '');
}

class TranscriptPanel extends StatefulWidget {
  final List<String> history;
  final String draft;
  final String label;
  final bool showCursor;
  final bool showEllipsis;
  final bool roundedTop;
  final bool showSpeakerToggle;
  final bool speakerEnabled;
  final VoidCallback? onSpeakerToggle;

  /// When true and the panel has no text yet, shows a "Listening…" pulse so the
  /// warm-up window (before the first tokens arrive) doesn't look frozen.
  final bool isRecording;

  /// When true, force the draft to render standalone (on a new line) even if
  /// this panel's own history doesn't have a trailing empty entry. Used by
  /// the translation panel to mirror the transcription panel's paragraph
  /// break state, so both drafts go to a new line together after a silence.
  final bool forceDraftStandalone;

  const TranscriptPanel({
    super.key,
    required this.history,
    required this.draft,
    required this.label,
    this.showCursor = false,
    this.showEllipsis = false,
    this.roundedTop = false,
    this.showSpeakerToggle = false,
    this.speakerEnabled = false,
    this.onSpeakerToggle,
    this.isRecording = false,
    this.forceDraftStandalone = false,
  });

  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

class _TranscriptPanelState extends State<TranscriptPanel> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;
  Timer? _resumeTimer;
  Timer? _cursorTimer;
  bool _cursorVisible = true;
  Timer? _ellipsisTimer;
  int _ellipsisCount = 3;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    if (widget.showCursor) {
      _cursorTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() => _cursorVisible = !_cursorVisible);
      });
    }
    if (widget.showEllipsis) {
      _startEllipsisTimer();
    }
  }

  void _startEllipsisTimer() {
    _ellipsisTimer?.cancel();
    _ellipsisTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() => _ellipsisCount = (_ellipsisCount % 3) + 1);
    });
  }

  @override
  void didUpdateWidget(TranscriptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showEllipsis && !oldWidget.showEllipsis) {
      _startEllipsisTimer();
    } else if (!widget.showEllipsis && oldWidget.showEllipsis) {
      _ellipsisTimer?.cancel();
      _ellipsisTimer = null;
    }
    if (!_userScrolledUp) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _cursorTimer?.cancel();
    _ellipsisTimer?.cancel();
    _resumeTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    final isAway = (maxScroll - currentScroll) > 50;

    if (isAway) {
      _userScrolledUp = true;
      _resumeTimer?.cancel();
      _resumeTimer = Timer(const Duration(seconds: 3), _resumeAutoScroll);
    } else {
      _userScrolledUp = false;
      _resumeTimer?.cancel();
    }
  }

  void _resumeAutoScroll() {
    if (!mounted) return;
    _userScrolledUp = false;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  String get _allText {
    final lines = <String>[];
    for (int i = 0; i < widget.history.length; i++) {
      if (widget.history[i].trim().isEmpty) continue;
      lines.add(widget.history[i]);
    }
    if (widget.draft.isNotEmpty) {
      lines.add(widget.draft);
    }
    return lines.join('\n');
  }

  bool get _hasText =>
      widget.history.any((l) => l.trim().isNotEmpty) || widget.draft.isNotEmpty;

  void _copyAll() {
    Clipboard.setData(ClipboardData(text: _allText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppConstants.panelColor,
        borderRadius: widget.roundedTop
            ? const BorderRadius.only(
                topLeft: Radius.circular(AppConstants.panelBorderRadius),
                topRight: Radius.circular(AppConstants.panelBorderRadius),
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppConstants.panelPaddingH,
              top: 14,
              bottom: 4,
              right: 8,
            ),
            child: Row(
              children: [
                Text(
                  widget.label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: AppConstants.labelFontSize,
                    fontWeight: FontWeight.w400,
                    color: AppConstants.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                if (widget.showSpeakerToggle)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TtsControlButton(
                      enabled: widget.speakerEnabled,
                      onEnabledChanged: (v) {
                        if (v == widget.speakerEnabled) return;
                        widget.onSpeakerToggle?.call();
                      },
                    ),
                  ),
                if (_hasText)
                  GestureDetector(
                    onTap: _copyAll,
                    child: const Icon(
                      Icons.copy,
                      size: 18,
                      color: AppConstants.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: (!_hasText && widget.isRecording)
                ? const Center(child: ListeningIndicator())
                : SelectionArea(
                    child: ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppConstants.panelPaddingH,
                        vertical: 8,
                      ),
                      children: [
                        for (int i = 0; i < widget.history.length; i++)
                          if (widget.history[i].trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _isLastNonEmptyLine(i) &&
                                      _draftInline &&
                                      (widget.draft.isNotEmpty ||
                                          widget.showEllipsis)
                                  ? Text.rich(
                                      textDirection:
                                          directionOf(widget.history[i]),
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: widget.history[i],
                                            style: TextStyle(
                                              fontSize:
                                                  AppConstants.contentFontSize,
                                              color: AppConstants.textPrimary
                                                  .withOpacity(AppConstants
                                                      .historyOpacity),
                                              height: 1.5,
                                            ),
                                          ),
                                          TextSpan(
                                            text: ' ${_buildDraftText()}',
                                            style: const TextStyle(
                                              fontSize:
                                                  AppConstants.contentFontSize,
                                              color: AppConstants.textPrimary,
                                              fontWeight: FontWeight.w400,
                                              height: 1.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : Text(
                                      widget.history[i],
                                      textDirection:
                                          directionOf(widget.history[i]),
                                      style: TextStyle(
                                        fontSize: AppConstants.contentFontSize,
                                        color: AppConstants.textPrimary
                                            .withOpacity(
                                                AppConstants.historyOpacity),
                                        height: 1.5,
                                      ),
                                    ),
                            ),
                        // Draft standalone: no history yet, or new paragraph started (trailing empty line)
                        if (!_draftInline &&
                            (widget.draft.isNotEmpty || widget.showEllipsis))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              _cleanLineStart(_buildDraftText()),
                              textDirection: directionOf(_buildDraftText()),
                              style: const TextStyle(
                                fontSize: AppConstants.contentFontSize,
                                color: AppConstants.textPrimary,
                                fontWeight: FontWeight.w400,
                                height: 1.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Draft attaches inline only if the last history entry is non-empty
  /// (i.e. no new-paragraph timer has fired since the last confirmed text)
  /// AND the parent hasn't forced standalone rendering (used by the
  /// translation panel to mirror the transcription panel's paragraph break).
  bool get _draftInline =>
      !widget.forceDraftStandalone &&
      widget.history.isNotEmpty &&
      widget.history.last.trim().isNotEmpty;

  bool _isLastNonEmptyLine(int index) {
    for (int j = index + 1; j < widget.history.length; j++) {
      if (widget.history[j].trim().isNotEmpty) return false;
    }
    return true;
  }

  String _buildDraftText() {
    final dots = '.' * _ellipsisCount;
    if (widget.draft.isEmpty && widget.showEllipsis) {
      return dots;
    }
    String text = widget.draft;
    if (widget.showCursor && _cursorVisible) {
      text += '|';
    }
    if (widget.showEllipsis && widget.draft.isNotEmpty) {
      text += dots;
    }
    return text;
  }
}
