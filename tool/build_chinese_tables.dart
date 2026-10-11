// Builds the tables ChineseScriptConverter writes Chinese with
// (assets/chinese/s2tw.txt and t2s.txt) from OpenCC's dictionaries:
// https://github.com/BYVoid/OpenCC/tree/master/data/dictionary (Apache-2.0,
// copied next to the tables as LICENSE-OpenCC.txt).
//
//   dart run tool/build_chinese_tables.dart <dictionary dir> assets/chinese
//
// The dictionary dir needs STCharacters, STPhrases, TWVariants,
// TWVariantsPhrases, TSCharacters and TSPhrases (.txt). Each table folds one
// of OpenCC's conversion chains into a single longest-match table:
//  * s2tw: Simplified to Traditional with Taiwan standard characters
//    (OpenCC s2tw).
//  * t2s: Traditional, Taiwan or OpenCC standard, to Simplified (OpenCC t2s,
//    plus Taiwan variants mapped through their standard forms).
// Every line is `key<TAB>value`, sorted by key.

import 'dart:io';

/// First candidate per key: OpenCC lists alternatives most common first.
Map<String, String> _read(String dir, String name) {
  final table = <String, String>{};
  for (final line in File('$dir/$name.txt').readAsLinesSync()) {
    if (line.isEmpty || line.startsWith('#')) continue;
    final tab = line.indexOf('\t');
    if (tab <= 0) continue;
    final value = line.substring(tab + 1).trim().split(' ').first;
    if (value.isNotEmpty) table[line.substring(0, tab)] = value;
  }
  return table;
}

int _longest(Map<String, String> table) =>
    table.keys.fold(0, (n, k) => k.length > n ? k.length : n);

/// [text] through [table], longest key first (the same matching the app
/// does at run time).
String _convert(String text, Map<String, String> table, int longest) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    var matched = false;
    final maxLen = longest < text.length - i ? longest : text.length - i;
    for (var len = maxLen; len > 0; len--) {
      final value = table[text.substring(i, i + len)];
      if (value != null) {
        out.write(value);
        i += len;
        matched = true;
        break;
      }
    }
    if (!matched) {
      final unit = text.codeUnitAt(i);
      final pair = unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length;
      out.write(text.substring(i, pair ? i + 2 : i + 1));
      i += pair ? 2 : 1;
    }
  }
  return out.toString();
}

bool _isOneCharacter(String s) => s.runes.length == 1;

void _write(String path, Map<String, String> table) {
  final keys = table.keys.toList()..sort();
  final out = StringBuffer();
  for (final key in keys) {
    out
      ..write(key)
      ..write('\t')
      ..write(table[key])
      ..write('\n');
  }
  File(path).writeAsStringSync(out.toString());
  stdout.writeln('$path: ${keys.length} entries');
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
        'usage: dart run tool/build_chinese_tables.dart <dictionary dir> <out dir>');
    exitCode = 64;
    return;
  }
  final src = args[0];
  final out = args[1];
  Directory(out).createSync(recursive: true);

  // s2tw: STPhrases + STCharacters, then Taiwan variants on what they give.
  final variants = {
    ..._read(src, 'TWVariants'),
    ..._read(src, 'TWVariantsPhrases'),
  };
  final variantsLongest = _longest(variants);
  final s2tw = <String, String>{};
  final st = {..._read(src, 'STCharacters'), ..._read(src, 'STPhrases')};
  st.forEach((key, value) {
    final converted = _convert(value, variants, variantsLongest);
    // A character that stays itself needs no entry; a phrase that stays
    // itself still keeps a shorter phrase inside it from matching.
    if (converted != key || !_isOneCharacter(key)) s2tw[key] = converted;
  });
  // OpenCC-standard Traditional characters in the input still get their
  // Taiwan form.
  _read(src, 'TWVariants').forEach((key, value) {
    if (_isOneCharacter(key)) s2tw.putIfAbsent(key, () => value);
  });
  _write('$out/s2tw.txt', s2tw);

  // t2s: TSPhrases + TSCharacters. A Taiwan variant converts as the OpenCC
  // standard character it stands for.
  final ts = {..._read(src, 'TSCharacters'), ..._read(src, 'TSPhrases')};
  final t2s = <String, String>{};
  ts.forEach((key, value) {
    if (value != key || !_isOneCharacter(key)) t2s[key] = value;
  });
  _read(src, 'TWVariants').forEach((standard, taiwan) {
    if (!_isOneCharacter(standard) || !_isOneCharacter(taiwan)) return;
    if (ts.containsKey(taiwan)) return;
    final simplified = ts[standard] ?? standard;
    if (simplified != taiwan) t2s.putIfAbsent(taiwan, () => simplified);
  });
  _write('$out/t2s.txt', t2s);

  // OpenCC's LICENSE: next to the dictionaries, or at the root of a checkout.
  final license = [
    File('$src/LICENSE'),
    File('$src/../../LICENSE'),
  ].where((f) => f.existsSync());
  if (license.isEmpty) {
    stdout.writeln("Copy OpenCC's LICENSE to $out/LICENSE-OpenCC.txt");
  } else {
    license.first.copySync('$out/LICENSE-OpenCC.txt');
  }
}
