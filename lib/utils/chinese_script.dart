import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A way of writing Chinese. Soniox has a single Chinese (zh) and picks the
/// characters itself; the app shows the script the user chose.
enum ChineseScript {
  simplified('assets/chinese/t2s.txt'),
  traditional('assets/chinese/s2tw.txt');

  const ChineseScript(this.table);

  /// The table that converts into this script, built from OpenCC's
  /// dictionaries by tool/build_chinese_tables.dart.
  final String table;
}

/// Writes Chinese text in one script with OpenCC's tables (Apache-2.0, see
/// assets/chinese/LICENSE-OpenCC.txt): at each point the longest phrase or
/// character in the table is replaced. Phrases settle the characters whose
/// conversion depends on the word (头发 → 頭髮 but 发展 → 發展). Text in any
/// other script passes through unchanged.
class ChineseScriptConverter {
  ChineseScriptConverter.fromTable(String table) {
    for (final line in const LineSplitter().convert(table)) {
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final key = line.substring(0, tab);
      _table[key] = line.substring(tab + 1);
      final first = key.codeUnitAt(0);
      final longest = _longestFrom[first];
      if (longest == null || key.length > longest) {
        _longestFrom[first] = key.length;
      }
    }
  }

  final Map<String, String> _table = {};
  // Per first code unit, the longest key starting with it.
  final Map<int, int> _longestFrom = {};

  String convert(String text) {
    final out = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final unit = text.codeUnitAt(i);
      final longest = _longestFrom[unit];
      if (longest != null) {
        final maxLen = longest < text.length - i ? longest : text.length - i;
        String? value;
        var len = maxLen;
        for (; len > 0; len--) {
          value = _table[text.substring(i, i + len)];
          if (value != null) break;
        }
        if (value != null) {
          out.write(value);
          i += len;
          continue;
        }
      }
      // No match: copy the character, both halves of a surrogate pair.
      final pair = unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length;
      out.write(text.substring(i, pair ? i + 2 : i + 1));
      i += pair ? 2 : 1;
    }
    return out.toString();
  }

  static final _ready = <ChineseScript, ChineseScriptConverter>{};
  static final _loading = <ChineseScript, Future<ChineseScriptConverter?>>{};

  /// The converter into [script] once [load] has finished, else null.
  static ChineseScriptConverter? ready(ChineseScript script) => _ready[script];

  /// Reads [script]'s table once, parsing it off the UI isolate. Completes
  /// with null when the table can't be read; text then stays as Soniox wrote
  /// it, and a later call tries again.
  static Future<ChineseScriptConverter?> load(ChineseScript script) {
    final ready = _ready[script];
    if (ready != null) return SynchronousFuture(ready);
    return _loading[script] ??= _load(script);
  }

  static Future<ChineseScriptConverter?> _load(ChineseScript script) async {
    try {
      final data = await rootBundle.load(script.table);
      final converter = await compute(_parseTable, data);
      _ready[script] = converter;
      return converter;
    } catch (e) {
      debugPrint('Chinese ${script.name} table failed to load: $e');
      return null;
    } finally {
      _loading.remove(script);
    }
  }
}

ChineseScriptConverter _parseTable(ByteData data) =>
    ChineseScriptConverter.fromTable(utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    ));
