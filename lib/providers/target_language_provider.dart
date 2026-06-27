import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TargetLanguage {
  vietnamese('Vietnamese', 'vi'),
  english('English', 'en'),
  turkish('Turkish', 'tr'),
  chinese('Chinese', 'zh'),
  korean('Korean', 'ko'),
  japanese('Japanese', 'ja'),
  thai('Thai', 'th'),
  malay('Malay', 'ms'),
  russian('Russian', 'ru'),
  indonesian('Indonesian', 'id');

  const TargetLanguage(this.displayName, this.code);
  final String displayName;
  final String code;

  static TargetLanguage fromCode(String code) {
    return TargetLanguage.values.firstWhere(
      (l) => l.code == code,
      orElse: () => TargetLanguage.vietnamese,
    );
  }
}

final targetLanguageProvider =
    StateProvider<TargetLanguage>((ref) => TargetLanguage.vietnamese);

/// Source language. `null` = "Any" (auto-detect). When set, it's passed to
/// Soniox as a language hint so the user can pin e.g. English → Vietnamese.
final sourceLanguageProvider = StateProvider<TargetLanguage?>((ref) => null);

/// Load saved language on app start
Future<TargetLanguage> loadSavedTargetLanguage() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString('target_language');
  if (code == null) return TargetLanguage.vietnamese;
  return TargetLanguage.fromCode(code);
}

/// Persist language selection
Future<void> saveTargetLanguage(TargetLanguage lang) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('target_language', lang.code);
}

/// Load saved source language on app start (null = "Any").
Future<TargetLanguage?> loadSavedSourceLanguage() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString('source_language');
  if (code == null) return null;
  return TargetLanguage.fromCode(code);
}

/// Persist source language selection (null = "Any").
Future<void> saveSourceLanguage(TargetLanguage? lang) async {
  final prefs = await SharedPreferences.getInstance();
  if (lang == null) {
    await prefs.remove('source_language');
  } else {
    await prefs.setString('source_language', lang.code);
  }
}

/// Load the most-recently-used target languages (most recent first). Used by
/// Quick Mode's swap button to pick a sensible "reply" language when it can't
/// be inferred from the transcription.
Future<List<TargetLanguage>> loadRecentTargets() async {
  final prefs = await SharedPreferences.getInstance();
  final codes = prefs.getStringList('recent_targets') ?? const [];
  return codes.map(TargetLanguage.fromCode).toList();
}

/// Persist the most-recently-used target language list (most recent first).
Future<void> saveRecentTargets(List<TargetLanguage> langs) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
    'recent_targets',
    langs.map((l) => l.code).toList(),
  );
}
