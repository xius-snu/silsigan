// Chinese (Simplified) and Chinese (Traditional), added 2026-10. Soniox has a
// single Chinese (zh) and writes it in characters of its choosing, so the app
// writes each entry in its own script with OpenCC's tables (assets/chinese).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silsigan/providers/target_language_provider.dart';
import 'package:silsigan/utils/chinese_script.dart';

ChineseScriptConverter _table(String name) => ChineseScriptConverter.fromTable(
    File('assets/chinese/$name.txt').readAsStringSync());

void main() {
  group('ChineseScriptConverter', () {
    final traditional = _table('s2tw');
    final simplified = _table('t2s');

    test('to Traditional, words settling ambiguous characters', () {
      expect(traditional.convert('我们的头发'), '我們的頭髮');
      expect(traditional.convert('发展经济'), '發展經濟');
      expect(traditional.convert('干净'), '乾淨');
      expect(traditional.convert('以后再说'), '以後再說');
      // Phrases that keep characters as they are.
      expect(traditional.convert('皇后'), '皇后');
      expect(traditional.convert('乾隆'), '乾隆');
      // Taiwan standard forms.
      expect(traditional.convert('里面'), '裡面');
    });

    test('to Simplified, from Taiwan and standard Traditional', () {
      expect(simplified.convert('我們的頭髮'), '我们的头发');
      expect(simplified.convert('發展經濟'), '发展经济');
      expect(simplified.convert('臺灣'), '台湾');
      expect(simplified.convert('裡面'), '里面');
      expect(simplified.convert('乾隆'), '乾隆');
    });

    test('text already in the script, and other scripts, pass through', () {
      expect(simplified.convert('我们的头发'), '我们的头发');
      expect(traditional.convert('我們的頭髮'), '我們的頭髮');
      const mixed = 'Hello 안녕하세요 123 😀!';
      expect(traditional.convert(mixed), mixed);
      expect(simplified.convert(mixed), mixed);
      expect(simplified.convert('頭😀髮'), '头😀发');
    });
  });

  group('Chinese entries', () {
    test('both are zh to Soniox, each with its own script and code', () {
      expect(TargetLanguage.chinese.sonioxCode, 'zh');
      expect(TargetLanguage.chineseTraditional.sonioxCode, 'zh');
      expect(TargetLanguage.chinese.chineseScript, ChineseScript.simplified);
      expect(TargetLanguage.chineseTraditional.chineseScript,
          ChineseScript.traditional);
      expect(TargetLanguage.korean.chineseScript, isNull);
      expect(TargetLanguage.korean.sonioxCode, 'ko');
      final codes = TargetLanguage.values.map((l) => l.code).toList();
      expect(codes.toSet(), hasLength(codes.length));
    });

    test('a "Chinese" saved before the split stays Simplified', () {
      expect(TargetLanguage.fromCode('zh'), TargetLanguage.chinese);
      expect(
        TargetLanguage.fromCode('zh-Hant'),
        TargetLanguage.chineseTraditional,
      );
    });
  });

  group('chineseScriptFor', () {
    ChineseScript? lineByLine({
      required bool translation,
      required String? language,
      TargetLanguage? source,
      TargetLanguage target = TargetLanguage.english,
    }) =>
        chineseScriptFor(
          translation: translation,
          language: language,
          conversation: false,
          source: source,
          target: target,
          my: TargetLanguage.korean,
          their: TargetLanguage.vietnamese,
        );

    test('translations follow the target', () {
      expect(
        lineByLine(
          translation: true,
          language: 'ko',
          target: TargetLanguage.chineseTraditional,
        ),
        ChineseScript.traditional,
      );
      expect(lineByLine(translation: true, language: 'zh'), isNull);
    });

    test('a transcript follows the source only when pinned and spoken', () {
      expect(
        lineByLine(
          translation: false,
          language: 'zh',
          source: TargetLanguage.chineseTraditional,
        ),
        ChineseScript.traditional,
      );
      // Any: Soniox's own characters.
      expect(lineByLine(translation: false, language: 'zh'), isNull);
      // Pinned to Chinese, but someone spoke Korean.
      expect(
        lineByLine(
          translation: false,
          language: 'ko',
          source: TargetLanguage.chinese,
        ),
        isNull,
      );
    });

    test('Simplified source to Traditional target converts between them', () {
      expect(
        lineByLine(
          translation: false,
          language: 'zh',
          source: TargetLanguage.chinese,
          target: TargetLanguage.chineseTraditional,
        ),
        ChineseScript.simplified,
      );
      expect(
        lineByLine(
          translation: true,
          language: 'zh',
          source: TargetLanguage.chinese,
          target: TargetLanguage.chineseTraditional,
        ),
        ChineseScript.traditional,
      );
    });

    test('Conversation writes each side in its own language', () {
      ChineseScript? conversation(bool translation, String language) =>
          chineseScriptFor(
            translation: translation,
            language: language,
            conversation: true,
            source: null,
            target: TargetLanguage.english,
            my: TargetLanguage.korean,
            their: TargetLanguage.chineseTraditional,
          );
      // Their Chinese speech, and its Korean translation.
      expect(conversation(false, 'zh'), ChineseScript.traditional);
      expect(conversation(true, 'zh'), isNull);
      // My Korean speech, and its Chinese translation.
      expect(conversation(false, 'ko'), isNull);
      expect(conversation(true, 'ko'), ChineseScript.traditional);
      // Neither side's language.
      expect(conversation(true, 'ja'), isNull);
    });
  });
}
