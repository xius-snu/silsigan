import 'package:flutter_riverpod/flutter_riverpod.dart';

enum TargetLanguage {
  vietnamese('Vietnamese', 'vi'),
  english('English', 'en'),
  turkish('Turkish', 'tr'),
  korean('Korean', 'ko');

  const TargetLanguage(this.displayName, this.code);
  final String displayName;
  final String code;
}

final targetLanguageProvider =
    StateProvider<TargetLanguage>((ref) => TargetLanguage.vietnamese);
