import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/chinese_script.dart';

enum TargetLanguage {
  vietnamese('Vietnamese', 'vi'),
  english('English', 'en'),
  turkish('Turkish', 'tr'),
  // Soniox has one Chinese, so both are zh to it; the app writes each in
  // its own script (ChineseScriptConverter). Simplified keeps the old
  // "Chinese" code, so a saved choice of it stays put.
  chinese('Chinese (Simplified)', 'zh', shortName: 'Chinese (Simp.)'),
  chineseTraditional(
    'Chinese (Traditional)',
    'zh-Hant',
    shortName: 'Chinese (Trad.)',
    sonioxCode: 'zh',
  ),
  korean('Korean', 'ko'),
  japanese('Japanese', 'ja'),
  thai('Thai', 'th'),
  malay('Malay', 'ms'),
  russian('Russian', 'ru'),
  indonesian('Indonesian', 'id'),
  arabic('Arabic', 'ar'),
  persian('Persian', 'fa'),
  french('French', 'fr');

  const TargetLanguage(
    this.displayName,
    this.code, {
    String? shortName,
    String? sonioxCode,
  })  : _shortName = shortName,
        _sonioxCode = sonioxCode;

  final String displayName;

  /// The app's own code: saved in preferences and drafts, and the key for
  /// read-aloud voices.
  final String code;

  final String? _shortName;
  final String? _sonioxCode;

  /// What the fixed-width language boxes show.
  String get shortName => _shortName ?? displayName;

  /// The language Soniox knows this as: what its session config takes and
  /// what it reports as detected.
  String get sonioxCode => _sonioxCode ?? code;

  /// The script Chinese text is shown in, for the two Chinese entries.
  ChineseScript? get chineseScript => switch (this) {
        chinese => ChineseScript.simplified,
        chineseTraditional => ChineseScript.traditional,
        _ => null,
      };

  static TargetLanguage fromCode(String code) {
    return TargetLanguage.values.firstWhere(
      (l) => l.code == code,
      orElse: () => TargetLanguage.vietnamese,
    );
  }
}

/// The script for text Soniox sends, or null when it isn't Chinese with a
/// chosen script. [translation] says which stream the text is from and
/// [language] is the language it was spoken in, as Soniox reports it. In
/// Conversation each side's speech is written in its own language ([my] or
/// [their]) and translated into the other side's. Otherwise translations are
/// in [target], and the transcript has a script only when [source] is pinned.
ChineseScript? chineseScriptFor({
  required bool translation,
  required String? language,
  required bool conversation,
  required TargetLanguage? source,
  required TargetLanguage target,
  required TargetLanguage my,
  required TargetLanguage their,
}) {
  if (conversation) {
    if (language == my.sonioxCode) {
      return (translation ? their : my).chineseScript;
    }
    if (language == their.sonioxCode) {
      return (translation ? my : their).chineseScript;
    }
    return null;
  }
  if (translation) return target.chineseScript;
  if (source == null || language != source.sonioxCode) return null;
  return source.chineseScript;
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
/// the language swap arrow to pick a sensible "reply" language when it can't
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
