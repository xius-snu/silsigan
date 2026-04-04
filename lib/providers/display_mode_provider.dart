import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DisplayMode { lineByLine, split, conversation, transcription }

final displayModeProvider =
    StateProvider<DisplayMode>((ref) => DisplayMode.split);

Future<DisplayMode> loadSavedDisplayMode() async {
  final prefs = await SharedPreferences.getInstance();
  final name = prefs.getString('display_mode');
  if (name == null) return DisplayMode.split;
  return DisplayMode.values.firstWhere(
    (m) => m.name == name,
    orElse: () => DisplayMode.split,
  );
}

Future<void> saveDisplayMode(DisplayMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('display_mode', mode.name);
}
