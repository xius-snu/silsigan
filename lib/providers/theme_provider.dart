import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether dark mode is on. Toggle-driven only — defaults to light and is
/// deliberately independent of the OS brightness setting. The saved value is
/// loaded in main() (before runApp) and injected via a provider override, so
/// the first frame already renders in the right theme with no flash.
final darkModeProvider = StateProvider<bool>((ref) => false);

Future<bool> loadSavedDarkMode() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('dark_mode') ?? false;
}

Future<void> saveDarkMode(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('dark_mode', enabled);
}
