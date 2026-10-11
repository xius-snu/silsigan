// Saved-session tap-to-seek (history sheet).
//
// Reported 2026-10 (1.1.4 / 1.1.5): a tap on a word in the middle or end of a
// long recording jumped to somewhere near the start, and some words couldn't
// be tapped at all. Saved word times were Soniox-session times that restarted
// at every 10-minute rotation and reconnect, and tokens were matched to the
// line text with the leading space and punctuation they carry.

import 'package:flutter_test/flutter_test.dart';
import 'package:silsigan/models/word_timestamp.dart';
import 'package:silsigan/utils/word_timeline.dart';

List<WordTimestamp> _words(List<(String, int)> words) =>
    [for (final (text, ms) in words) WordTimestamp(text, ms)];

/// The tappable text and times of one line's spans.
List<(String, int)> _tapped(String line, List<int> spans) => [
      for (var i = 0; i + 2 < spans.length; i += 3)
        (line.substring(spans[i], spans[i + 1]), spans[i + 2]),
    ];

void main() {
  group('wordsOnRecordingTimeline', () {
    test('times that only rise come back untouched', () {
      final lines = [
        _words([('Hello', 0), (' there', 400)]),
        _words([(' Twenty', 1200000), (' minutes', 1200500)]),
      ];
      expect(identical(wordsOnRecordingTimeline(lines), lines), isTrue);
    });

    test('a session after a full rotation starts ten minutes later', () {
      final out = wordsOnRecordingTimeline([
        _words([('one', 1000), (' two', 590000)]),
        // Rotation: Soniox's clock restarts.
        _words([(' three', 4000), (' four', 598000)]),
        // And again.
        _words([(' five', 2000)]),
      ]);
      expect(out[0].map((w) => w.startMs), [1000, 590000]);
      expect(out[1].map((w) => w.startMs), [604000, 1198000]);
      expect(out[2].map((w) => w.startMs), [1202000]);
      expect(out[1][0].text, ' three');
    });

    test('a session after a short one starts after its last word', () {
      // A reconnect two minutes in, or a recording continued after Stop.
      final out = wordsOnRecordingTimeline([
        _words([('one', 1000), (' two', 120000)]),
        _words([(' three', 800)]),
      ]);
      expect(out[1].single.startMs, 120000 + 500 + 800);
    });

    test('jitter between words is not a new session', () {
      final lines = [
        _words([('one', 5000), (' two', 4200)]),
      ];
      expect(identical(wordsOnRecordingTimeline(lines), lines), isTrue);
    });
  });

  group('alignWordSpans', () {
    test("a line's first word is tappable despite its token's space", () {
      const lines = ['Good morning.', 'How are you?'];
      final spans = alignWordSpans(lines, [
        _words([(' Good', 100), (' morning', 400), ('.', 700)]),
        _words([(' How', 1000), (' are', 1200), (' you', 1400), ('?', 1600)]),
      ]);
      expect(_tapped(lines[0], spans[0]),
          [('Good', 100), ('morning', 400), ('.', 700)]);
      expect(_tapped(lines[1], spans[1]),
          [('How', 1000), ('are', 1200), ('you', 1400), ('?', 1600)]);
    });

    test('a stripped leading comma does not swallow the words after it', () {
      // The line was saved without the comma its first token carried.
      const lines = ['and then we went, finally'];
      final spans = alignWordSpans(lines, [
        _words([
          (',', 0),
          (' and', 100),
          (' then', 200),
          (' we', 300),
          (' went', 400),
          (',', 500),
          (' finally', 600),
        ]),
      ]);
      expect(_tapped(lines[0], spans[0]), [
        ('and', 100),
        ('then', 200),
        ('we', 300),
        ('went', 400),
        (',', 500),
        ('finally', 600),
      ]);
    });

    test('subword tokens and scripts without spaces', () {
      const lines = ['beautiful 오늘 회의'];
      final spans = alignWordSpans(lines, [
        _words([
          (' beau', 0),
          ('ti', 100),
          ('ful', 200),
          (' 오늘', 300),
          (' 회', 400),
          ('의', 500),
        ]),
      ]);
      expect(_tapped(lines[0], spans[0]), [
        ('beau', 0),
        ('ti', 100),
        ('ful', 200),
        ('오늘', 300),
        ('회', 400),
        ('의', 500),
      ]);
    });

    test('words follow an edit that joined two lines', () {
      const lines = ['First line. Second line.'];
      final spans = alignWordSpans(lines, [
        _words([(' First', 0), (' line', 300), ('.', 600)]),
        _words([(' Second', 1000), (' line', 1300), ('.', 1600)]),
      ]);
      expect(_tapped(lines[0], spans[0]), [
        ('First', 0),
        ('line', 300),
        ('.', 600),
        ('Second', 1000),
        ('line', 1300),
        ('.', 1600),
      ]);
    });

    test('words pick up again after a long inserted passage', () {
      final inserted = List.filled(30, 'note').join(' ');
      final lines = ['We met today. $inserted Then we left early.'];
      final spans = alignWordSpans(lines, [
        _words([(' We', 0), (' met', 200), (' today', 400), ('.', 600)]),
        _words(
            [(' Then', 900), (' we', 1100), (' left', 1300), (' early', 1500)]),
      ]);
      final tapped = _tapped(lines[0], spans[0]);
      expect(tapped.take(4),
          [('We', 0), ('met', 200), ('today', 400), ('.', 600)]);
      expect(tapped.skip(4), [
        ('Then', 900),
        ('we', 1100),
        ('left', 1300),
        ('early', 1500),
      ]);
    });

    test('a line with no words stays plain and the next still matches', () {
      const lines = ['Hello there', 'typed by hand', 'Bye now'];
      final spans = alignWordSpans(lines, [
        _words([(' Hello', 0), (' there', 300)]),
        _words([(' Bye', 2000), (' now', 2300)]),
      ]);
      expect(spans[1], isEmpty);
      expect(_tapped(lines[2], spans[2]), [('Bye', 2000), ('now', 2300)]);
    });

    test('a word edited away is skipped, not matched further along', () {
      const lines = ['I recieved it and the box'];
      final spans = alignWordSpans(lines, [
        _words([
          (' I', 0),
          (' received', 200),
          (' it', 600),
          (' and', 800),
          (' the', 900),
          (' box', 1000),
        ]),
      ]);
      expect(_tapped(lines[0], spans[0]), [
        ('I', 0),
        ('it', 600),
        ('and', 800),
        ('the', 900),
        ('box', 1000),
      ]);
    });
  });
}
