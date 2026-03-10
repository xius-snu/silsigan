import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/constants.dart';

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
  });

  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

class _TranscriptPanelState extends State<TranscriptPanel> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;
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
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    _userScrolledUp = (maxScroll - currentScroll) > 50;
  }

  String get _allText {
    final lines = widget.history.where((l) => l.trim().isNotEmpty).toList();
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
                  GestureDetector(
                    onTap: widget.onSpeakerToggle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        widget.speakerEnabled
                            ? Icons.volume_up
                            : Icons.volume_off_outlined,
                        size: 20,
                        color: widget.speakerEnabled
                            ? AppConstants.textPrimary
                            : AppConstants.textSecondary,
                      ),
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
            child: SelectionArea(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppConstants.panelPaddingH,
                  vertical: 8,
                ),
                children: [
                  ...widget.history
                      .where((line) => line.trim().isNotEmpty)
                      .map(
                        (line) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            line,
                            style: TextStyle(
                              fontSize: AppConstants.contentFontSize,
                              color: AppConstants.textPrimary
                                  .withOpacity(AppConstants.historyOpacity),
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                  if (widget.draft.isNotEmpty || widget.showEllipsis)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _buildDraftText(),
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
