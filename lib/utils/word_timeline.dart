import '../models/word_timestamp.dart';

/// Older versions saved each word's start as Soniox reported it: time from
/// the start of the Soniox session the word came from. A new session opens
/// every 10 minutes (rotation), after a dropped connection, and when a
/// recording is continued, so saved times fell back toward zero at each of
/// those points and a tap on a word past the first ten minutes jumped near
/// the start of the recording.
///
/// This puts such a session on the recording's timeline. A word that starts
/// well before the latest one opens a new Soniox session. When the session
/// before it ran nearly ten minutes, its rotation timer ended it, so the new
/// one began a full rotation after it. Otherwise it was a reconnect or a
/// continued recording, whose exact start wasn't saved, and it is placed just
/// after the previous session's last word. Times that never fall back, which
/// is what this version saves, come back unchanged.
List<List<WordTimestamp>> wordsOnRecordingTimeline(
  List<List<WordTimestamp>> lines,
) {
  const rotationMs = 10 * 60 * 1000;
  // A session whose words reach this far ran until its rotation.
  const fullSessionMs = 9 * 60 * 1000;
  // A word this much earlier than the latest one belongs to a new session.
  const fallBackMs = 2000;
  // Where a reconnect is assumed to begin after the last word heard.
  const reconnectGapMs = 500;

  var base = 0;
  var latest = -1;
  List<List<WordTimestamp>>? out;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    for (var j = 0; j < line.length; j++) {
      final s = line[j].startMs;
      if (latest >= 0 && s + fallBackMs < latest) {
        final lastWord = base + latest;
        final next = latest >= fullSessionMs
            ? base + rotationMs
            : lastWord + reconnectGapMs;
        base = next > lastWord ? next : lastWord;
        latest = s;
      } else if (s > latest) {
        latest = s;
      }
      if (base == 0) continue;
      out ??= [for (final l in lines) List.of(l)];
      out[i][j] = WordTimestamp(line[j].text, base + s);
    }
  }
  return out ?? lines;
}

/// How far past the last match a word may sit and still be matched outright
/// (spacing, or a few words typed in by an edit).
const _nearChars = 48;

/// How far a word is looked for when it isn't near, as after a longer
/// insertion. Such a match only counts when the next words follow it.
const _resyncChars = 4000;

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Where each word of a saved session sits in its transcript as it reads
/// now. For each of [lines], flat `[start, end, ms]` triples: the characters
/// of that line the word covers, then where the word starts in the recording.
///
/// Words are matched in order across the whole transcript, not line by line,
/// because an edited transcript can join, split or drop lines. Tokens are
/// matched without the space they usually start with, since a line never
/// starts with one; the first word of nearly every line used to be
/// untappable for that. Punctuation only matches where the text continues:
/// a line's leading comma is stripped, and that token used to match a later
/// comma and leave every word before it untappable. Text no word matches
/// stays plain.
List<List<int>> alignWordSpans(
  List<String> lines,
  List<List<WordTimestamp>> words,
) {
  final spans = [for (var i = 0; i < lines.length; i++) <int>[]];
  if (lines.isEmpty) return spans;
  final text = lines.join('\n');
  final lineStarts = <int>[];
  var offset = 0;
  for (final line in lines) {
    lineStarts.add(offset);
    offset += line.length + 1;
  }

  final tokens = <String>[];
  final times = <int>[];
  for (final line in words) {
    for (final w in line) {
      final token = w.text.trim();
      if (token.isEmpty) continue;
      tokens.add(token);
      times.add(w.startMs);
    }
  }

  var cursor = 0;
  var lineIdx = 0;
  for (var k = 0; k < tokens.length; k++) {
    final token = tokens[k];
    var at = -1;
    if (_letterOrDigit.hasMatch(token)) {
      final next = text.indexOf(token, cursor);
      if (next >= 0 &&
          (next - cursor <= _nearChars ||
              (next - cursor <= _resyncChars &&
                  _continuesAt(text, next + token.length, tokens, k + 1)))) {
        at = next;
      }
    } else {
      at = _punctuationAt(text, token, cursor);
    }
    if (at < 0) continue;
    while (lineIdx + 1 < lineStarts.length && lineStarts[lineIdx + 1] <= at) {
      lineIdx++;
    }
    final start = at - lineStarts[lineIdx];
    spans[lineIdx]
      ..add(start)
      ..add(start + token.length)
      ..add(times[k]);
    cursor = at + token.length;
  }
  return spans;
}

/// [token] right at [from], or after a single whitespace character.
int _punctuationAt(String text, String token, int from) {
  if (text.startsWith(token, from)) return from;
  if (from < text.length &&
      text[from].trim().isEmpty &&
      text.startsWith(token, from + 1)) {
    return from + 1;
  }
  return -1;
}

/// Whether the next two words pick up right after [pos]: evidence that a
/// match found further along is where the transcript really continues.
bool _continuesAt(String text, int pos, List<String> tokens, int from) {
  var confirmed = 0;
  for (var k = from; k < tokens.length && confirmed < 2; k++) {
    final token = tokens[k];
    if (!_letterOrDigit.hasMatch(token)) {
      final at = _punctuationAt(text, token, pos);
      if (at >= 0) pos = at + token.length;
      continue;
    }
    final at = text.indexOf(token, pos);
    if (at < 0 || at - pos > 3) return false;
    pos = at + token.length;
    confirmed++;
  }
  return true;
}
