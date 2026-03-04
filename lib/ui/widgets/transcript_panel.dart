import 'dart:async';
import 'package:flutter/material.dart';
import '../../utils/constants.dart';

class TranscriptPanel extends StatefulWidget {
  final List<String> history;
  final String draft;
  final String label;
  final bool showCursor;
  final bool showEllipsis;
  final bool roundedTop;

  const TranscriptPanel({
    super.key,
    required this.history,
    required this.draft,
    required this.label,
    this.showCursor = false,
    this.showEllipsis = false,
    this.roundedTop = false,
  });

  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

class _TranscriptPanelState extends State<TranscriptPanel> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;
  Timer? _cursorTimer;
  bool _cursorVisible = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    if (widget.showCursor) {
      _cursorTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() => _cursorVisible = !_cursorVisible);
      });
    }
  }

  @override
  void dispose() {
    _cursorTimer?.cancel();
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

  @override
  void didUpdateWidget(TranscriptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
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
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppConstants.panelPaddingH,
              top: 14,
              bottom: 4,
            ),
            child: Text(
              widget.label.toUpperCase(),
              style: const TextStyle(
                fontSize: AppConstants.labelFontSize,
                fontWeight: FontWeight.w400,
                color: AppConstants.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                horizontal: AppConstants.panelPaddingH,
                vertical: 8,
              ),
              children: [
                ...widget.history.map(
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
        ],
      ),
    );
  }

  String _buildDraftText() {
    if (widget.draft.isEmpty && widget.showEllipsis) {
      return '...';
    }
    String text = widget.draft;
    if (widget.showCursor && _cursorVisible) {
      text += '|';
    }
    if (widget.showEllipsis && widget.draft.isNotEmpty) {
      text += '...';
    }
    return text;
  }
}
