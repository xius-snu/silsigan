import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final ttsEnabledProvider = StateProvider<bool>((ref) => false);

/// TTS playback speed as a multiplier of the platform's natural-for-learners
/// base rate (iOS 0.45, Android 0.75). 1.0 = current default; 0.5 = half;
/// 1.5 = 50% faster.
final ttsRateProvider = StateProvider<double>((ref) => 1.0);

Future<double> loadSavedTtsRate() async {
  final prefs = await SharedPreferences.getInstance();
  final value = prefs.getDouble('tts_rate');
  if (value == null) return 1.0;
  return value.clamp(0.5, 1.5);
}

Future<void> saveTtsRate(double rate) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setDouble('tts_rate', rate);
}
