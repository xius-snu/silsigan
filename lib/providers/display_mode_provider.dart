import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DisplayMode { lineByLine, split, conversation, transcription, quick }

final displayModeProvider =
    StateProvider<DisplayMode>((ref) => DisplayMode.lineByLine);

const _seenSplitViewTipKey = 'seen_split_view_tip';
const _hasRecordedSplitKey = 'has_recorded_split';

Future<DisplayMode> loadSavedDisplayMode() async {
  final prefs = await SharedPreferences.getInstance();
  final name = prefs.getString('display_mode');
  if (name == null) return DisplayMode.lineByLine;
  final mode = DisplayMode.values.firstWhere(
    (m) => m.name == name,
    orElse: () => DisplayMode.lineByLine,
  );
  // Already using Split View — never coach them toward a mode they know.
  if (mode == DisplayMode.split) {
    await prefs.setBool(_seenSplitViewTipKey, true);
  }
  return mode;
}

Future<void> saveDisplayMode(DisplayMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('display_mode', mode.name);
  if (mode == DisplayMode.split) {
    await prefs.setBool(_seenSplitViewTipKey, true);
  }
}

/// True if the Split View coach-mark has been dismissed, or the user already
/// switched to / recorded in Split View.
Future<bool> hasSeenSplitViewTip() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getBool(_seenSplitViewTipKey) ?? false) ||
      (prefs.getBool(_hasRecordedSplitKey) ?? false);
}

Future<void> markSplitViewTipSeen() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_seenSplitViewTipKey, true);
}

/// Persist that the user has recorded in Split View so the line-by-line
/// coach-mark never appears later.
Future<void> markHasRecordedSplit() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_hasRecordedSplitKey, true);
  await prefs.setBool(_seenSplitViewTipKey, true);
}
