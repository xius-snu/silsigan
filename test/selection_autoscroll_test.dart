// Regression test for the "selecting transcript text during a live recording
// turns the whole screen gray" bug.
//
// Root cause: while recording, every incoming token rebuild auto-scrolled the
// panel to maxScrollExtent (didUpdateWidget -> animateTo). Once content
// exceeded one screen, that yank happened mid-selection-drag, so the selection
// expanded over everything that scrolled past — a full-screen highlight film.
//
// The fix suppresses auto-scroll (including the 3s resume timer) while a text
// selection is active in the panel, and re-arms it when the selection is
// dismissed. This test proves both halves behaviorally for LineByLinePanel:
//  1. with an active selection, appending history lines does NOT scroll to
//     the bottom (offset frozen), even after 5+ seconds of timers firing;
//  2. after the selection is dismissed, appending lines DOES auto-scroll to
//     the bottom again — the guard is selection-specific.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silsigan/ui/widgets/line_by_line_panel.dart';

Future<void> pumpPanel(WidgetTester tester, int pairs) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 400,
            child: LineByLinePanel(
              transcriptionHistory: [
                for (int i = 0; i < pairs; i++) 'Source line $i alpha beta',
              ],
              transcriptionDraft: '',
              translationHistory: [
                for (int i = 0; i < pairs; i++) 'Target line $i gamma delta',
              ],
              translationDraft: '',
              isRecording: true,
            ),
          ),
        ),
      ),
    ),
  );
}

ScrollPosition panelPosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byType(ListView),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable).position;
}

/// The panel runs a periodic ellipsis timer while recording, so
/// pumpAndSettle can hang — advance time with bounded pumps instead.
Future<void> pumpFor(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 100),
}) async {
  var elapsed = Duration.zero;
  while (elapsed < total) {
    await tester.pump(step);
    elapsed += step;
  }
}

void main() {
  testWidgets(
      'live auto-scroll is suppressed while text is selected and resumes '
      'after the selection is dismissed', (tester) async {
    // 30 transcription+translation pairs in a 400px-tall panel: content is
    // several screens tall.
    await pumpPanel(tester, 30);
    await tester.pump(const Duration(milliseconds: 50));

    var position = panelPosition(tester);
    expect(position.maxScrollExtent, greaterThan(400),
        reason: 'test needs content taller than the viewport');

    // Baseline: with NO selection, appending a line auto-scrolls to bottom
    // (didUpdateWidget -> post-frame animateTo over 100ms). ListView only
    // estimates maxScrollExtent until children are laid out, so the first
    // animateTo can land short; the panel then treats the >50px gap as a
    // user scroll and relies on its 3s resume timer to finish the job.
    // Give each round enough time for that timer + its 300ms animation.
    for (int round = 0; round < 4; round++) {
      await pumpPanel(tester, 31);
      await pumpFor(tester, const Duration(seconds: 4),
          step: const Duration(milliseconds: 250));
      position = panelPosition(tester);
      if (position.maxScrollExtent - position.pixels < 1.0) break;
    }
    expect(
      position.pixels,
      moreOrLessEquals(position.maxScrollExtent, epsilon: 1.0),
      reason: 'sanity: auto-scroll must reach the bottom when nothing is '
          'selected',
    );

    // Start a selection: long-press a committed line near the bottom of the
    // viewport (SelectionArea selects the word under a touch long-press).
    // Press inside the first word — the paragraph's center can fall on the
    // boundary between wrapped lines, where the word lookup finds nothing.
    final committedLine = find.textContaining('Source line 30').hitTestable();
    expect(committedLine, findsOneWidget,
        reason: 'the last committed transcription line should be visible '
            'after auto-scroll');
    await tester
        .longPressAt(tester.getTopLeft(committedLine) + const Offset(25, 11));
    await pumpFor(tester, const Duration(milliseconds: 400));
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget,
        reason: 'long-press should have selected a word (toolbar shown)');

    final offsetDuringSelection = panelPosition(tester).pixels;

    // Simulate incoming tokens: rebuild with more history lines while the
    // selection is active, then give every auto-scroll path a chance to run
    // (post-frame animateTo now, 3s resume timers later).
    await pumpPanel(tester, 36);
    await pumpFor(tester, const Duration(seconds: 5),
        step: const Duration(milliseconds: 250));

    position = panelPosition(tester);
    expect(
      position.pixels,
      moreOrLessEquals(offsetDuringSelection, epsilon: 1.0),
      reason: 'FIX: the viewport must not move while a selection is active — '
          'pre-fix it jumped to maxScrollExtent and dragged the selection '
          'over the whole transcript',
    );
    expect(
      position.maxScrollExtent - position.pixels,
      greaterThan(200.0),
      reason: 'appended lines grew the scroll extent, so staying put means '
          'auto-scroll was genuinely suppressed',
    );

    // Dismiss the selection with a tap near the top of the list, away from
    // the selection toolbar/handles.
    await tester
        .tapAt(tester.getTopLeft(find.byType(ListView)) + const Offset(60, 40));
    await tester.pump(const Duration(milliseconds: 100));

    // Append more lines with no selection active: auto-scroll must work
    // again (directly, or via the <=3s resume timer + 300ms animation).
    // Same convergence caveat as the baseline: each round re-triggers the
    // auto-scroll like the next incoming token would.
    for (int round = 0; round < 4; round++) {
      await pumpPanel(tester, 40);
      await pumpFor(tester, const Duration(seconds: 4),
          step: const Duration(milliseconds: 250));
      position = panelPosition(tester);
      if (position.maxScrollExtent - position.pixels < 1.0) break;
    }
    expect(
      position.pixels,
      moreOrLessEquals(position.maxScrollExtent, epsilon: 1.0),
      reason: 'the guard is selection-specific: once the selection is '
          'dismissed, live auto-scroll must resume',
    );

    // Dispose the panel so its periodic timers do not outlive the test.
    await tester.pumpWidget(const SizedBox());
  });
}
