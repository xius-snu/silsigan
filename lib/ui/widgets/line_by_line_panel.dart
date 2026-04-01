import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/elevenlabs_tts_service.dart';
import '../../utils/constants.dart';

class LineByLinePanel extends StatefulWidget {
  final List<String> transcriptionHistory;
  final String transcriptionDraft;
  final List<String> translationHistory;
  final String translationDraft;
  final bool isRecording;
  final bool showSpeakerToggle;
  final bool speakerEnabled;
  final VoidCallback? onSpeakerToggle;
  final Function(String text)? onSpeakLine;
  final ValueNotifier<({String? text, TtsLineStatus status})>? ttsLineState;

  const LineByLinePanel({
    super.key,
    required this.transcriptionHistory,
    required this.transcriptionDraft,
    required this.translationHistory,
    required this.translationDraft,
    required this.isRecording,
    this.showSpeakerToggle = false,
    this.speakerEnabled = false,
    this.onSpeakerToggle,
    this.onSpeakLine,
    this.ttsLineState,
  });

  @override
  State<LineByLinePanel> createState() => _LineByLinePanelState();
}

class _LineByLinePanelState extends State<LineByLinePanel> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;
  Timer? _resumeTimer;
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
    _resumeTimer?.cancel();
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
    final buffer = StringBuffer();
    final count = max(
        widget.transcriptionHistory.length, widget.translationHistory.length);
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
    final rawCount = max(
        widget.transcriptionHistory.length, widget.translationHistory.length);
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
        widgets.add(_buildTranscriptionBlock(
          widget.transcriptionHistory[i],
        ));
      }

      if (hasTranslation) {
        widgets.add(_buildTranslationBlock(widget.translationHistory[i]));
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
                  ...widgets,
                  // Live transcription draft (always at bottom — current speech)
                  if (widget.transcriptionDraft.isNotEmpty) ...[
                    if (widgets.isNotEmpty) const SizedBox(height: 12),
                    _buildTranscriptionBlock(
                      widget.transcriptionDraft,
                      isDraft: true,
                    ),
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
    final baseStyle = TextStyle(
      fontSize: AppConstants.contentFontSize,
      color: isDraft
          ? AppConstants.textPrimary
          : AppConstants.textPrimary.withOpacity(AppConstants.historyOpacity),
      height: 1.5,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: baseStyle),
    );
  }

  Widget _buildLineIcon(TtsLineStatus status) {
    switch (status) {
      case TtsLineStatus.loading:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppConstants.textSecondary,
          ),
        );
      case TtsLineStatus.playing:
        return const _PulsingIcon(
          icon: Icons.stop_rounded,
          size: 20,
          color: AppConstants.textPrimary,
        );
      case TtsLineStatus.idle:
        return const Icon(
          Icons.volume_up_outlined,
          size: 18,
          color: AppConstants.textSecondary,
        );
    }
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
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
            if (!isDraft &&
                widget.showSpeakerToggle &&
                widget.onSpeakLine != null &&
                widget.ttsLineState != null)
              ValueListenableBuilder<({String? text, TtsLineStatus status})>(
                valueListenable: widget.ttsLineState!,
                builder: (context, state, _) {
                  final isThisLine = state.text == text;
                  return GestureDetector(
                    onTap: () => widget.onSpeakLine?.call(text),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, top: 2),
                      child: _buildLineIcon(
                          isThisLine ? state.status : TtsLineStatus.idle),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _PulsingIcon extends StatefulWidget {
  final IconData icon;
  final double size;
  final Color color;

  const _PulsingIcon({
    required this.icon,
    required this.size,
    required this.color,
  });

  @override
  State<_PulsingIcon> createState() => _PulsingIconState();
}

class _PulsingIconState extends State<_PulsingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: 0.4 + 0.6 * _controller.value,
        child: child,
      ),
      child: Icon(widget.icon, size: widget.size, color: widget.color),
    );
  }
}
