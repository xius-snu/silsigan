// Long saved sessions on Windows and macOS: the scrollbar jumped up and down
// while scrolling (reported 2026-10). The session's rows are built lazily,
// and Flutter estimated the height of the unbuilt rest from the average of
// the built rows, which differ a lot in height.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silsigan/ui/widgets/transcript_rows.dart';

const _style = TextStyle(fontSize: 15, height: 1.5);
const _width = 400.0;
const _viewport = 600.0;
const _labelRow = 30.0;

/// Lines from one word to a long paragraph, unevenly mixed.
final _lines = [
  for (var i = 0; i < 400; i++)
    List.filled(1 + (i * 37) % 61, 'word').join(' '),
];

Widget _row(BuildContext context, int index) {
  if (index == 0) return const SizedBox(height: _labelRow);
  if (index == 1) return const SizedBox(height: transcriptLabelGap);
  return Padding(
    padding: const EdgeInsets.only(bottom: transcriptLineSpacing),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(_lines[index - 2]),
    ),
  );
}

Widget _box(
  ScrollController controller,
  SliverChildDelegate delegate, {
  int generation = 0,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: DefaultTextStyle(
      style: _style,
      child: Center(
        child: SizedBox(
          width: _width,
          height: _viewport,
          child: CustomScrollView(
            controller: controller,
            slivers: [
              RelayoutSliver(
                generation: generation,
                sliver: SliverList(delegate: delegate),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

TranscriptRowHeights _heights() => TranscriptRowHeights(
      text: _lines.join('\n'),
      maxWidth: _width,
      style: _style,
    );

/// Every max scroll extent seen while scrolling to the end in steps.
Future<Set<double>> _extentsWhileScrolling(
  WidgetTester tester,
  ScrollController controller,
) async {
  final seen = {controller.position.maxScrollExtent};
  while (controller.offset < controller.position.maxScrollExtent) {
    controller.jumpTo(
      min(controller.offset + 300, controller.position.maxScrollExtent),
    );
    await tester.pump();
    seen.add(controller.position.maxScrollExtent);
  }
  return seen;
}

void main() {
  testWidgets('without measured heights the extent wanders (the bug)',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_box(
      controller,
      SliverChildBuilderDelegate(_row, childCount: _lines.length + 2),
    ));
    final seen = await _extentsWhileScrolling(tester, controller);
    expect(seen.length, greaterThan(5));
  });

  testWidgets('measured heights hold the extent still from the first frame',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final heights = _heights()..measure(const Duration(seconds: 30));
    expect(heights.isComplete, isTrue);
    await tester.pumpWidget(_box(
      controller,
      TranscriptRowsDelegate(
        _row,
        childCount: _lines.length + 2,
        heights: heights,
      ),
    ));
    final exact =
        _labelRow + transcriptLabelGap + heights.heightFrom(0)! - _viewport;
    expect(controller.position.maxScrollExtent, moreOrLessEquals(exact));
    final seen = await _extentsWhileScrolling(tester, controller);
    expect(seen, hasLength(1));
  });

  testWidgets('measuring that finishes later shows without a scroll',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final heights = _heights();
    Widget box(int generation) => _box(
          controller,
          TranscriptRowsDelegate(
            _row,
            childCount: _lines.length + 2,
            heights: heights,
          ),
          generation: generation,
        );
    await tester.pumpWidget(box(0));
    heights.measure(const Duration(seconds: 30));
    await tester.pumpWidget(box(1));
    final exact =
        _labelRow + transcriptLabelGap + heights.heightFrom(0)! - _viewport;
    expect(controller.position.maxScrollExtent, moreOrLessEquals(exact));
  });

  // The history sheet measures every line as plain text, but a line with
  // word timestamps is laid out as one span per word under a root span
  // carrying the theme's own size and height.
  testWidgets('a tappable line is as tall as the plain line measured',
      (tester) async {
    final line = _lines[60];
    final words = line.split(' ');
    final plainKey = GlobalKey();
    final tappableKey = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: const TextStyle(fontSize: 14, height: 1.43, letterSpacing: 0.25),
        child: Center(
          child: SizedBox(
            width: _width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line, key: plainKey, style: _style),
                Text.rich(
                  key: tappableKey,
                  TextSpan(children: [
                    for (var i = 0; i < words.length; i++)
                      TextSpan(
                        text: i == 0 ? words[i] : ' ${words[i]}',
                        style: _style,
                      ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    expect(
      tester.getSize(find.byKey(tappableKey)).height,
      tester.getSize(find.byKey(plainKey)).height,
    );
  });

  test('lines not measured yet count at the measured average', () {
    final heights = TranscriptRowHeights(
      text: List.filled(10, 'same').join('\n'),
      maxWidth: _width,
      style: _style,
    );
    expect(heights.heightFrom(0), isNull);
    // A zero budget still measures one line.
    heights.measure(Duration.zero);
    expect(heights.isComplete, isFalse);
    final row = heights.heightFrom(9)!;
    expect(heights.heightFrom(0), moreOrLessEquals(row * 10));
    expect(heights.heightFrom(10), 0);
  });
}
