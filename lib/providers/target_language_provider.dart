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
  malay('Malay', 'ms');

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
