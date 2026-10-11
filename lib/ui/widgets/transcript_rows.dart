import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../utils/text_direction_utils.dart';

/// Space below each line row of a saved session's text box.
const double transcriptLineSpacing = 8;

/// Gap between a text box's label row and its first line.
const double transcriptLabelGap = 12;

/// The heights of a text box's line rows, measured with the text layout the
/// rows get but without building them.
///
/// The history sheet builds a session's rows lazily, so Flutter estimates the
/// height of the rows it hasn't built from the average of the ones it has.
/// Lines run from a couple of words to whole paragraphs, so on a long session
/// that estimate, and the desktop scrollbar drawn from it, jumped back and
/// forth while scrolling. [TranscriptRowsDelegate] counts unbuilt rows at
/// these heights instead, which makes the scroll extent exact.
///
/// Each line goes through a [TextPainter] with the style, scaling, locale and
/// width its Text gets. [measure] works in slices, so a session of thousands
/// of lines never holds up a frame for more than a few milliseconds.
class TranscriptRowHeights {
  TranscriptRowHeights({
    required this.text,
    required this.maxWidth,
    required this.style,
    this.textScaler = TextScaler.noScaling,
    this.locale,
    this.textHeightBehavior,
  }) : _lines = text.split('\n');

  /// The box's text, one row per line.
  final String text;
  final double maxWidth;
  final TextStyle style;
  final TextScaler textScaler;
  final Locale? locale;
  final TextHeightBehavior? textHeightBehavior;

  final List<String> _lines;
  // Height of the rows for lines 0 to i - 1.
  late final Float64List _sums = Float64List(_lines.length + 1);
  int _measured = 0;

  bool get isComplete => _measured == _lines.length;

  /// Whether these are the heights of [text]'s rows laid out this way.
  bool fits({
    required String text,
    required double maxWidth,
    required TextStyle style,
    required TextScaler textScaler,
    required Locale? locale,
    required TextHeightBehavior? textHeightBehavior,
  }) =>
      maxWidth == this.maxWidth &&
      textScaler == this.textScaler &&
      locale == this.locale &&
      textHeightBehavior == this.textHeightBehavior &&
      style == this.style &&
      text == this.text;

  /// Measures lines in order until [budget] is spent.
  void measure(Duration budget) {
    if (isComplete) return;
    final clock = Stopwatch()..start();
    final painter = TextPainter(
      textScaler: textScaler,
      locale: locale,
      textHeightBehavior: textHeightBehavior,
    );
    try {
      while (!isComplete) {
        final line = _lines[_measured];
        painter
          ..text = TextSpan(text: line, style: style)
          ..textDirection = directionOf(line)
          ..layout(maxWidth: maxWidth);
        _sums[_measured + 1] =
            _sums[_measured] + painter.height + transcriptLineSpacing;
        _measured++;
        if (clock.elapsed >= budget) break;
      }
    } finally {
      painter.dispose();
    }
  }

  /// Total height of the rows for lines [from] to the last, or null before
  /// any line is measured. Lines not measured yet count at the average.
  double? heightFrom(int from) {
    if (_measured == 0) return null;
    final count = _lines.length;
    if (from >= count) return 0;
    final measured = _sums[_measured];
    final average = measured / _measured;
    if (from >= _measured) return average * (count - from);
    return measured - _sums[from] + average * (count - _measured);
  }
}

/// A saved session's text box rows: the label (row 0), the gap below it
/// (row 1), then one row per line. Rows not built yet count at [heights]
/// rather than at the average of the built ones.
class TranscriptRowsDelegate extends SliverChildBuilderDelegate {
  TranscriptRowsDelegate(
    super.builder, {
    required super.childCount,
    required this.heights,
  });

  final TranscriptRowHeights heights;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) {
    // The row after lastIndex holds line lastIndex - 1, or the gap when
    // only the label is built.
    final lines = heights.heightFrom(lastIndex < 1 ? 0 : lastIndex - 1);
    if (lines == null) return null;
    return trailingScrollOffset +
        (lastIndex < 1 ? transcriptLabelGap : 0) +
        lines;
  }
}

/// Lays [sliver] out again whenever [generation] changes. Measuring finishes
/// without any widget changing, and a sliver that isn't laid out again keeps
/// its old scroll extent until the next scroll.
class RelayoutSliver extends SingleChildRenderObjectWidget {
  const RelayoutSliver({
    super.key,
    required this.generation,
    required Widget sliver,
  }) : super(child: sliver);

  final int generation;

  @override
  RenderRelayoutSliver createRenderObject(BuildContext context) =>
      RenderRelayoutSliver(generation);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderRelayoutSliver renderObject,
  ) {
    renderObject.generation = generation;
  }
}

class RenderRelayoutSliver extends RenderProxySliver {
  RenderRelayoutSliver(this._generation);

  int _generation;

  set generation(int value) {
    if (value == _generation) return;
    _generation = value;
    child?.markNeedsLayout();
  }
}
