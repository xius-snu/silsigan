import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectionStatus;
import 'package:flutter/services.dart';
import '../../services/tts_service.dart';
import '../../utils/constants.dart';
import '../../utils/text_direction_utils.dart';
import 'diarization_toggle_button.dart';
import 'listening_indicator.dart';
import 'speaker_label.dart';
import 'tts_control_button.dart';

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

  /// Per-line speaker ids, index-aligned with [transcriptionHistory]. When at
  /// least two distinct speakers are present, a small "SPEAKER N" label is
  /// shown above each transcription line where the speaker changes.
  final List<int?> speakers;

  /// Diarization toggle in the header, next to the TTS speaker toggle.
  final bool showDiarizationToggle;
  final bool diarizationEnabled;
  final ValueChanged<bool>? onDiarizationChanged;
  final bool diarizationInteractive;

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
    this.speakers = const [],
    this.showDiarizationToggle = false,
    this.diarizationEnabled = false,
    this.onDiarizationChanged,
    this.diarizationInteractive = true,
  });

  @override
  State<LineByLinePanel> createState() => _LineByLinePanelState();
}

class _LineByLinePanelState extends State<LineByLinePanel> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;
  // Selection state is read on demand from this notifier (geometry-based
  // ground truth) rather than latched from SelectionArea.onSelectionChanged,
  // which only fires for gestures and would stay stale when selected text is
  // removed programmatically (clear / new session).
  final SelectionListenerNotifier _selectionNotifier =
      SelectionListenerNotifier();
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
    // Auto-scroll only when content actually changed — parent rebuilds for
    // unrelated state shouldn't restart the scroll animation.
    final contentChanged = !identical(
            widget.transcriptionHistory, oldWidget.transcriptionHistory) ||
        !identical(widget.translationHistory, oldWidget.translationHistory) ||
        widget.transcriptionDraft != oldWidget.transcriptionDraft ||
        widget.translationDraft != oldWidget.translationDraft;
    if (contentChanged && !_userScrolledUp && !_hasActiveSelection) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _followTail(duration: const Duration(milliseconds: 100));
      });
    }
  }

  /// Keep the view pinned to the live tail without a per-token animation
  /// storm. Most streaming updates don't change the scroll extent at all
  /// (the draft grows within its current wrapped line), so skip those
  /// outright instead of restarting a scroll activity ~10x/s for the whole
  /// session — that constant animation churn was a measurable heat source
  /// over an hour of recording. When the gap is huge (first frame after a
  /// long screen-off stint, or a restored session), animating would force
  /// layout of every row it flies past — a multi-second stall that grows
  /// with the backlog — so jump straight to the end instead.
  void _followTail({required Duration duration}) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final gap = position.maxScrollExtent - position.pixels;
    if (gap < 1.0) return;
    if (gap > position.viewportDimension * 2) {
      _scrollController.jumpTo(position.maxScrollExtent);
    } else {
      _scrollController.animateTo(
        position.maxScrollExtent,
        duration: duration,
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _ellipsisTimer?.cancel();
    _resumeTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _selectionNotifier.dispose();
    super.dispose();
  }

  // While a text selection is active, auto-scroll must stay off: a jump to
  // the bottom mid-drag extends the selection over everything that scrolls
  // past, highlighting the whole transcript.
  bool get _hasActiveSelection =>
      _selectionNotifier.registered &&
      _selectionNotifier.selection.status == SelectionStatus.uncollapsed;

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
    if (_hasActiveSelection) {
      // Still selecting — retry later instead of leaving _userScrolledUp
      // latched true, which would kill auto-scroll for the session.
      _resumeTimer?.cancel();
      _resumeTimer = Timer(const Duration(seconds: 3), _resumeAutoScroll);
      return;
    }
    _userScrolledUp = false;
    _followTail(duration: const Duration(milliseconds: 300));
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

  /// Whether at least two distinct speakers were attributed — labels stay
  /// hidden for single-speaker sessions so they never distract.
  bool get _showSpeakerLabels {
    final distinct = <int>{};
    for (final s in widget.speakers) {
      if (s != null) distinct.add(s);
      if (distinct.length >= 2) return true;
    }
    return false;
  }

  /// Builds cheap row DESCRIPTORS for the full paired history — the actual
  /// widgets are only constructed for rows on screen (ListView.builder), so a
  /// long session doesn't pay an O(all-lines) widget rebuild on every
  /// streaming token or ellipsis tick. Shows the translation draft in-place
  /// within the first empty slot rather than at the bottom.
  List<_LineRowSpec> _buildRowSpecs() {
    final specs = <_LineRowSpec>[];
    final rawCount = max(
        widget.transcriptionHistory.length, widget.translationHistory.length);
    bool addedAny = false;
    bool translationDraftPlaced = false;
    final labelsOn = _showSpeakerLabels;
    int? prevSpeaker;

    for (int i = 0; i < rawCount; i++) {
      final hasTranscript = i < widget.transcriptionHistory.length &&
          widget.transcriptionHistory[i].trim().isNotEmpty;
      final hasTranslation = i < widget.translationHistory.length &&
          widget.translationHistory[i].trim().isNotEmpty;
      final isEmptySlot = i < widget.translationHistory.length &&
          widget.translationHistory[i].isEmpty;

      if (!hasTranscript && !hasTranslation && !isEmptySlot) continue;

      if (addedAny) specs.add(const _LineRowSpec(_LineRowKind.gap));

      if (hasTranscript) {
        final speaker = i < widget.speakers.length ? widget.speakers[i] : null;
        if (labelsOn && speaker != null && speaker != prevSpeaker) {
          specs.add(_LineRowSpec(_LineRowKind.speakerLabel, speaker));
        }
        if (speaker != null) prevSpeaker = speaker;
        specs.add(_LineRowSpec(_LineRowKind.transcription, i));
      }

      if (hasTranslation) {
        specs.add(_LineRowSpec(_LineRowKind.translation, i));
      } else if (isEmptySlot && !translationDraftPlaced) {
        // Show translation draft in-place within the first empty slot.
        // This is where the translation will land when it completes.
        if (widget.translationDraft.isNotEmpty ||
            (widget.isRecording && hasTranscript)) {
          specs.add(const _LineRowSpec(_LineRowKind.translationDraft));
          translationDraftPlaced = true;
        }
      }

      addedAny = true;
    }

    // Live transcription draft (always at bottom — current speech).
    if (widget.transcriptionDraft.isNotEmpty) {
      if (specs.isNotEmpty) specs.add(const _LineRowSpec(_LineRowKind.gap));
      specs.add(const _LineRowSpec(_LineRowKind.transcriptionDraft));
    }
    // Translation draft at bottom only if not already shown in-place.
    if (!translationDraftPlaced && widget.translationDraft.isNotEmpty) {
      specs.add(const _LineRowSpec(_LineRowKind.translationDraft));
    }

    return specs;
  }

  Widget _buildRow(_LineRowSpec spec) {
    switch (spec.kind) {
      case _LineRowKind.gap:
        return const SizedBox(height: 12);
      case _LineRowKind.speakerLabel:
        return Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 3),
          child: SpeakerLabel(spec.index),
        );
      case _LineRowKind.transcription:
        return _buildTranscriptionBlock(
            widget.transcriptionHistory[spec.index]);
      case _LineRowKind.translation:
        return _buildTranslationBlock(widget.translationHistory[spec.index]);
      case _LineRowKind.transcriptionDraft:
        return _buildTranscriptionBlock(widget.transcriptionDraft,
            isDraft: true);
      case _LineRowKind.translationDraft:
        final dots = '.' * _ellipsisCount;
        return _buildTranslationBlock(
          widget.translationDraft.isNotEmpty
              ? '${widget.translationDraft}$dots'
              : dots,
          isDraft: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final specs = _buildRowSpecs();

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
                Text(
                  'LINE BY LINE',
                  style: TextStyle(
                    fontSize: AppConstants.labelFontSize,
                    fontWeight: FontWeight.w400,
                    color: AppConstants.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                if (widget.showDiarizationToggle)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: DiarizationToggleButton(
                      enabled: widget.diarizationEnabled,
                      interactive: widget.diarizationInteractive,
                      onEnabledChanged: (v) =>
                          widget.onDiarizationChanged?.call(v),
                    ),
                  ),
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
                    child: Icon(
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
                // Warm-up window: session is live but the first tokens haven't
                // arrived yet — show a pulse so the empty panel isn't mistaken
                // for a freeze. Not const — a const instance is canonicalized
                // and would keep stale colors across a mid-warmup theme toggle.
                // ignore: prefer_const_constructors
                ? Center(child: ListeningIndicator())
                : SelectionArea(
                    child: SelectionListener(
                      selectionNotifier: _selectionNotifier,
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppConstants.panelPaddingH,
                          vertical: 8,
                        ),
                        itemCount: specs.length,
                        itemBuilder: (context, index) =>
                            _buildRow(specs[index]),
                      ),
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

    final block = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppConstants.lineTranscriptionBlockColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: baseStyle, textDirection: directionOf(text)),
    );
    // Draft text mutates as tokens stream in — keep it out of the selection
    // so an active selection can't re-anchor onto text that just changed.
    return isDraft ? SelectionContainer.disabled(child: block) : block;
  }

  Widget _buildLineIcon(TtsLineStatus status) {
    switch (status) {
      case TtsLineStatus.loading:
        return SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppConstants.textSecondary,
          ),
        );
      case TtsLineStatus.playing:
        return _PulsingIcon(
          icon: Icons.stop_rounded,
          size: 20,
          color: AppConstants.textPrimary,
        );
      case TtsLineStatus.idle:
        return Icon(
          Icons.volume_up_outlined,
          size: 18,
          color: AppConstants.textSecondary,
        );
    }
  }

  Widget _buildTranslationBlock(String text, {bool isDraft = false}) {
    final block = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppConstants.lineTranslationBlockColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          // RTL lines (e.g. Arabic) lay the row out right-to-left, so the
          // text right-aligns and the speaker icon moves to the left edge.
          textDirection: directionOf(text),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                text,
                textDirection: directionOf(text),
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
                      padding:
                          const EdgeInsetsDirectional.only(start: 8, top: 2),
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
    // See _buildTranscriptionBlock: drafts stay outside the selection.
    return isDraft ? SelectionContainer.disabled(child: block) : block;
  }
}

enum _LineRowKind {
  gap,
  speakerLabel,
  transcription,
  translation,
  transcriptionDraft,
  translationDraft,
}

/// Cheap per-row descriptor computed for the full history each build; the
/// corresponding widget is only built for rows inside the viewport.
/// [index] is the history index for transcription/translation rows and the
/// speaker id for speakerLabel rows.
class _LineRowSpec {
  final _LineRowKind kind;
  final int index;

  const _LineRowSpec(this.kind, [this.index = 0]);
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
