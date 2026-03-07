import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../utils/constants.dart';

class LineByLinePanel extends StatefulWidget {
  final List<String> transcriptionHistory;
  final String transcriptionDraft;
  final List<String> translationHistory;
  final String translationDraft;
  final bool isRecording;

  const LineByLinePanel({
    super.key,
    required this.transcriptionHistory,
    required this.transcriptionDraft,
    required this.translationHistory,
    required this.translationDraft,
    required this.isRecording,
  });

  @override
  State<LineByLinePanel> createState() => _LineByLinePanelState();
}

class _LineByLinePanelState extends State<LineByLinePanel> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;
  Timer? _ellipsisTimer;
  int _ellipsisCount = 3;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    if (widget.isRecording) {
      _startEllipsisTimer();
    }
  }

  @override
  void didUpdateWidget(LineByLinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !oldWidget.isRecording) {
      _startEllipsisTimer();
    } else if (!widget.isRecording && oldWidget.isRecording) {
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
    _ellipsisTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _startEllipsisTimer() {
    _ellipsisTimer?.cancel();
    _ellipsisTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() => _ellipsisCount = (_ellipsisCount % 3) + 1);
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    _userScrolledUp = (maxScroll - currentScroll) > 50;
  }

  String get _allText {
    final buffer = StringBuffer();
    final count = max(widget.transcriptionHistory.length,
        widget.translationHistory.length);
    for (int i = 0; i < count; i++) {
      if (i < widget.transcriptionHistory.length &&
          widget.transcriptionHistory[i].trim().isNotEmpty) {
        buffer.writeln(widget.transcriptionHistory[i]);
      }
      if (i < widget.translationHistory.length &&
          widget.translationHistory[i].trim().isNotEmpty) {
        buffer.writeln(widget.translationHistory[i]);
      }
    }
    if (widget.transcriptionDraft.isNotEmpty) {
      buffer.writeln(widget.transcriptionDraft);
    }
    if (widget.translationDraft.isNotEmpty) {
      buffer.writeln(widget.translationDraft);
    }
    return buffer.toString().trimRight();
  }

  bool get _hasText =>
      widget.transcriptionHistory.any((l) => l.trim().isNotEmpty) ||
      widget.translationHistory.any((l) => l.trim().isNotEmpty) ||
      widget.transcriptionDraft.isNotEmpty ||
      widget.translationDraft.isNotEmpty;

  void _copyAll() {
    Clipboard.setData(ClipboardData(text: _allText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  /// Builds paired widgets using raw indices. Shows translation draft
  /// in-place within the first empty slot rather than at the bottom.
  ({List<Widget> widgets, bool translationDraftPlaced}) _buildPairedWidgets() {
    final widgets = <Widget>[];
    final rawCount = max(widget.transcriptionHistory.length,
        widget.translationHistory.length);
    bool addedAny = false;
    bool translationDraftPlaced = false;

    for (int i = 0; i < rawCount; i++) {
      final hasTranscript = i < widget.transcriptionHistory.length &&
          widget.transcriptionHistory[i].trim().isNotEmpty;
      final hasTranslation = i < widget.translationHistory.length &&
          widget.translationHistory[i].trim().isNotEmpty;
      final isEmptySlot = i < widget.translationHistory.length &&
          widget.translationHistory[i].isEmpty;

      if (!hasTranscript && !hasTranslation && !isEmptySlot) continue;

      if (addedAny) widgets.add(const SizedBox(height: 12));

      if (hasTranscript) {
        widgets.add(
            _buildTranscriptionBlock(widget.transcriptionHistory[i]));
      }

      if (hasTranslation) {
        widgets.add(
            _buildTranslationBlock(widget.translationHistory[i]));
      } else if (isEmptySlot && !translationDraftPlaced) {
        // Show translation draft in-place within the first empty slot.
        // This is where the translation will land when it completes.
        if (widget.translationDraft.isNotEmpty) {
          widgets.add(_buildTranslationBlock(
            '${widget.translationDraft}${'.' * _ellipsisCount}',
            isDraft: true,
          ));
          translationDraftPlaced = true;
        } else if (widget.isRecording && hasTranscript) {
          widgets.add(_buildTranslationBlock(
            '.' * _ellipsisCount,
            isDraft: true,
          ));
          translationDraftPlaced = true;
        }
      }

      addedAny = true;
    }

    return (widgets: widgets, translationDraftPlaced: translationDraftPlaced);
  }

  @override
  Widget build(BuildContext context) {
    final (:widgets, :translationDraftPlaced) = _buildPairedWidgets();

    return Container(
      decoration: BoxDecoration(
        color: AppConstants.panelColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(AppConstants.panelBorderRadius),
          topRight: Radius.circular(AppConstants.panelBorderRadius),
        ),
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
                const Text(
                  'LINE BY LINE',
                  style: TextStyle(
                    fontSize: AppConstants.labelFontSize,
                    fontWeight: FontWeight.w400,
                    color: AppConstants.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
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
                  ...widgets,
                  // Live transcription draft (always at bottom — current speech)
                  if (widget.transcriptionDraft.isNotEmpty) ...[
                    if (widgets.isNotEmpty) const SizedBox(height: 12),
                    _buildTranscriptionBlock(widget.transcriptionDraft,
                        isDraft: true),
                  ],
                  // Translation draft at bottom only if not already shown in-place
                  if (!translationDraftPlaced &&
                      widget.translationDraft.isNotEmpty)
                    _buildTranslationBlock(
                      '${widget.translationDraft}${'.' * _ellipsisCount}',
                      isDraft: true,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscriptionBlock(String text, {bool isDraft = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppConstants.contentFontSize,
          color: isDraft
              ? AppConstants.textPrimary
              : AppConstants.textPrimary
                  .withOpacity(AppConstants.historyOpacity),
          height: 1.5,
        ),
      ),
    );
  }

  Widget _buildTranslationBlock(String text, {bool isDraft = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F0FE),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppConstants.contentFontSize,
            color: isDraft
                ? AppConstants.textPrimary
                : AppConstants.textPrimary
                    .withOpacity(AppConstants.historyOpacity),
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
