import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DisplayMode { lineByLine, split, conversation, transcription, quick }

final displayModeProvider =
    StateProvider<DisplayMode>((ref) => DisplayMode.lineByLine);

Future<DisplayMode> loadSavedDisplayMode() async {
  final prefs = await SharedPreferences.getInstance();
  final name = prefs.getString('display_mode');
  if (name == null) return DisplayMode.lineByLine;
  return DisplayMode.values.firstWhere(
    (m) => m.name == name,
    orElse: () => DisplayMode.lineByLine,
  );
}

Future<void> saveDisplayMode(DisplayMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('display_mode', mode.name);
}
