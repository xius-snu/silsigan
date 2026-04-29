import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'target_language_provider.dart';

/// The user's native language for Learn mode — used when calling /api/learn/explain
/// to translate AI responses into something the learner already understands.
final nativeLanguageProvider =
    StateProvider<TargetLanguage>((ref) => TargetLanguage.english);

Future<TargetLanguage> loadSavedNativeLanguage() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString('native_language');
  if (code != null) return TargetLanguage.fromCode(code);

  final localeCode = PlatformDispatcher.instance.locale.languageCode;
  return TargetLanguage.values.firstWhere(
    (l) => l.code == localeCode,
    orElse: () => TargetLanguage.english,
  );
}

Future<void> saveNativeLanguage(TargetLanguage lang) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('native_language', lang.code);
}
