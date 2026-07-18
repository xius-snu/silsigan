import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectionStatus;
import 'package:flutter/services.dart';
import '../../utils/constants.dart';
import '../../utils/text_direction_utils.dart';
import 'diarization_toggle_button.dart';
import 'listening_indicator.dart';
import 'speaker_label.dart';
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

  /// Per-line speaker ids, index-aligned with [history]. When at least two
  /// distinct speakers are present, a small "SPEAKER N" label is shown above
  /// each line where the speaker changes from the previous one.
  final List<int?> speakers;

  /// Diarization toggle in the header (transcription panel only).
  final bool showDiarizationToggle;
  final bool diarizationEnabled;
  final ValueChanged<bool>? onDiarizationChanged;
  final bool diarizationInteractive;

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
    this.speakers = const [],
    this.showDiarizationToggle = false,
    this.diarizationEnabled = false,
    this.onDiarizationChanged,
    this.diarizationInteractive = true,
    this.isRecording = false,
    this.forceDraftStandalone = false,
  });

  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

class _TranscriptPanelState extends State<TranscriptPanel> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;
  // Selection state is read on demand from this notifier (geometry-based
  // ground truth) rather than latched from SelectionArea.onSelectionChanged,
  // which only fires for gestures and would stay stale when selected text is
  // removed programmatically (clear / new session).
  final SelectionListenerNotifier _selectionNotifier =
      SelectionListenerNotifier();
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
      _startCursorTimer();
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

  void _startCursorTimer() {
    _cursorTimer?.cancel();
    _cursorTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _cursorVisible = !_cursorVisible);
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
    // The cursor blink tracks transitions too — it used to be started only in
    // initState, so a panel mounted before recording never blinked and one
    // mounted mid-draft kept a 2Hz setState alive after the draft ended.
    if (widget.showCursor && !oldWidget.showCursor) {
      _startCursorTimer();
    } else if (!widget.showCursor && oldWidget.showCursor) {
      _cursorTimer?.cancel();
      _cursorTimer = null;
      _cursorVisible = true;
    }
    // Auto-scroll only when content actually changed — parent rebuilds for
    // unrelated state shouldn't restart the scroll animation.
    final contentChanged = !identical(widget.history, oldWidget.history) ||
        widget.draft != oldWidget.draft ||
        widget.showEllipsis != oldWidget.showEllipsis;
    if (contentChanged && !_userScrolledUp && !_hasActiveSelection) {
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
    _selectionNotifier.dispose();
    super.dispose();
  }

  // While a text selection is active, auto-scroll must stay off: a jump to
  // the bottom mid-drag extends the selection over everything that scrolls
  // past, highlighting the whole transcript.
  bool get _hasActiveSelection =>
      _selectionNotifier.registered &&
      _selectionNotifier.selection.status == SelectionStatus.uncollapsed;

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
            // Not const: a const ListeningIndicator would be canonicalized and
            // skip rebuilds, keeping stale colors if the theme toggles while
            // the warm-up pulse is visible.
            child: (!_hasText && widget.isRecording)
                // ignore: prefer_const_constructors
                ? Center(child: ListeningIndicator())
                : SelectionArea(
                    child: SelectionListener(
                      selectionNotifier: _selectionNotifier,
                      child: _buildLazyList(),
                    ),
                  ),
          ),
        ],
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

  /// Lazily-built history list. Row DESCRIPTORS for the whole history are
  /// cheap (ints/bools); the actual widgets are only constructed for rows on
  /// screen, so a long session doesn't pay an O(all-lines) widget rebuild on
  /// every streaming token or ellipsis tick.
  Widget _buildLazyList() {
    final labelsOn = _showSpeakerLabels;

    int lastNonEmpty = -1;
    for (int i = widget.history.length - 1; i >= 0; i--) {
      if (widget.history[i].trim().isNotEmpty) {
        lastNonEmpty = i;
        break;
      }
    }

    final specs = <_TranscriptRowSpec>[];
    int? prevSpeaker;
    for (int i = 0; i < widget.history.length; i++) {
      if (widget.history[i].trim().isEmpty) continue;
      final speaker = i < widget.speakers.length ? widget.speakers[i] : null;
      final showLabel = labelsOn && speaker != null && speaker != prevSpeaker;
      if (speaker != null) prevSpeaker = speaker;
      specs.add(_TranscriptRowSpec(
        historyIndex: i,
        speaker: speaker,
        showLabel: showLabel,
        fuseDraft: i == lastNonEmpty &&
            _draftInline &&
            (widget.draft.isNotEmpty || widget.showEllipsis),
      ));
    }

    // Draft standalone: no history yet, or new paragraph started (trailing
    // empty line).
    final standaloneDraft =
        !_draftInline && (widget.draft.isNotEmpty || widget.showEllipsis);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: AppConstants.panelPaddingH,
        vertical: 8,
      ),
      itemCount: specs.length + (standaloneDraft ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= specs.length) return _buildStandaloneDraft();
        return _buildHistoryRow(specs[index]);
      },
    );
  }

  /// One history paragraph, optionally preceded by a "SPEAKER N" label when
  /// the speaker changes from the previous visible paragraph.
  Widget _buildHistoryRow(_TranscriptRowSpec spec) {
    final i = spec.historyIndex;
    final Widget text = spec.fuseDraft
        // The in-progress paragraph fuses committed text with the draft
        // (cursor '|' / ellipsis dots / streaming tokens) in one selectable
        // paragraph that mutates several times a second — a selection
        // touching it would flicker, re-anchor onto new words, and copy
        // draft artifacts. Keep the whole line out of the selection until
        // its paragraph completes.
        ? SelectionContainer.disabled(
            child: Text.rich(
              textDirection: directionOf(widget.history[i]),
              TextSpan(
                children: [
                  TextSpan(
                    text: widget.history[i],
                    style: TextStyle(
                      fontSize: AppConstants.contentFontSize,
                      color: AppConstants.textPrimary
                          .withOpacity(AppConstants.historyOpacity),
                      height: 1.5,
                    ),
                  ),
                  TextSpan(
                    text: ' ${_buildDraftText()}',
                    style: TextStyle(
                      fontSize: AppConstants.contentFontSize,
                      color: AppConstants.textPrimary,
                      fontWeight: FontWeight.w400,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          )
        : Text(
            widget.history[i],
            textDirection: directionOf(widget.history[i]),
            style: TextStyle(
              fontSize: AppConstants.contentFontSize,
              color: AppConstants.textPrimary
                  .withOpacity(AppConstants.historyOpacity),
              height: 1.5,
            ),
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: spec.showLabel
          // stretch, not start: start gives the line loose width, which
          // shrink-wraps short RTL (Arabic/Persian) lines onto the LEFT
          // edge; stretch keeps the full-width layout unlabeled lines get
          // from the ListView, so their right-alignment is preserved.
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: SpeakerLabel(spec.speaker!),
                ),
                text,
              ],
            )
          : text,
    );
  }

  // Draft text mutates as tokens stream in — keep it out of the selection so
  // an active selection can't re-anchor onto text that just changed.
  Widget _buildStandaloneDraft() {
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          _cleanLineStart(_buildDraftText()),
          textDirection: directionOf(_buildDraftText()),
          style: TextStyle(
            fontSize: AppConstants.contentFontSize,
            color: AppConstants.textPrimary,
            fontWeight: FontWeight.w400,
            height: 1.5,
          ),
        ),
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

/// Cheap per-row descriptor computed for the full history each build; the
/// corresponding widget is only built for rows inside the viewport.
class _TranscriptRowSpec {
  final int historyIndex;
  final int? speaker;
  final bool showLabel;
  final bool fuseDraft;

  const _TranscriptRowSpec({
    required this.historyIndex,
    required this.speaker,
    required this.showLabel,
    required this.fuseDraft,
  });
}
