import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import '../models/transcript_session.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._();
  static Database? _database;

  DatabaseService._();

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final fullPath = '$dbPath/silsigan.db';
    return openDatabase(
      fullPath,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            korean_full TEXT NOT NULL,
            vietnamese_full TEXT NOT NULL,
            korean_preview TEXT NOT NULL,
            vietnamese_preview TEXT NOT NULL,
            audio_path TEXT,
            timestamps_json TEXT,
            title TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE autosave_draft (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            korean_history TEXT NOT NULL,
            vietnamese_history TEXT NOT NULL,
            word_timestamps TEXT,
            target_language TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE sessions ADD COLUMN audio_path TEXT',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE sessions ADD COLUMN timestamps_json TEXT',
          );
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS autosave_draft (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              korean_history TEXT NOT NULL,
              vietnamese_history TEXT NOT NULL,
              word_timestamps TEXT,
              target_language TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE sessions ADD COLUMN title TEXT',
          );
        }
      },
    );
  }

  // ── Autosave draft ──────────────────────────────────────────────────

  Future<void> saveAutosaveDraft(Map<String, dynamic> draft) async {
    final db = await database;
    draft['id'] = 1;
    await db.insert(
      'autosave_draft',
      draft,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getAutosaveDraft() async {
    final db = await database;
    final maps = await db.query(
      'autosave_draft',
      where: 'id = ?',
      whereArgs: [1],
    );
    if (maps.isEmpty) return null;
    return maps.first;
  }

  Future<void> clearAutosaveDraft() async {
    final db = await database;
    await db.delete('autosave_draft');
  }

  Future<List<TranscriptSession>> getAllSessions() async {
    final db = await database;
    final maps = await db.query('sessions', orderBy: 'created_at DESC');
    return maps.map((map) => TranscriptSession.fromMap(map)).toList();
  }

  Future<TranscriptSession?> getSession(int id) async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return TranscriptSession.fromMap(maps.first);
  }

  Future<int> insertSession(TranscriptSession session) async {
    final db = await database;
    return db.insert('sessions', session.toMap());
  }

  Future<TranscriptSession?> getSessionByCreatedAt(String createdAt) async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'created_at = ?',
      whereArgs: [createdAt],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return TranscriptSession.fromMap(maps.first);
  }

  Future<void> updateSessionTitleByCreatedAt(
      String createdAt, String title) async {
    final db = await database;
    await db.update(
      'sessions',
      {'title': title},
      where: 'created_at = ?',
      whereArgs: [createdAt],
    );
  }

  /// Patch cloud-synced fields on an existing local row. audio_path stays
  /// untouched — audio never leaves the device that recorded it.
  Future<void> updateSessionFromServer({
    required String createdAt,
    required String koreanFull,
    required String vietnameseFull,
    required String koreanPreview,
    required String vietnamesePreview,
    String? timestampsJson,
    String? title,
  }) async {
    final db = await database;
    final values = <String, dynamic>{
      'korean_full': koreanFull,
      'vietnamese_full': vietnameseFull,
      'korean_preview': koreanPreview,
      'vietnamese_preview': vietnamesePreview,
    };
    if (timestampsJson != null) {
      values['timestamps_json'] = timestampsJson;
    }
    if (title != null) {
      values['title'] = title;
    }
    await db.update(
      'sessions',
      values,
      where: 'created_at = ?',
      whereArgs: [createdAt],
    );
  }

  Future<void> deleteSessionByCreatedAt(String createdAt) async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'created_at = ?',
      whereArgs: [createdAt],
    );
    for (final map in maps) {
      final audioPath = map['audio_path'] as String?;
      if (audioPath != null) {
        final file = File(audioPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    await db
        .delete('sessions', where: 'created_at = ?', whereArgs: [createdAt]);
  }

  Future<int> getSessionCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM sessions');
    return (result.first['cnt'] as int?) ?? 0;
  }

  Future<void> updateSessionTitle(int id, String title) async {
    final db = await database;
    await db.update(
      'sessions',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<String> exportAllSessionsAsJson() async {
    final sessions = await getAllSessions();
    final exportData = {
      'app': 'Silsigan',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'session_count': sessions.length,
      'sessions': sessions
          .map((s) => {
                'created_at': s.createdAt,
                'transcription': s.koreanFull,
                'translation': s.vietnameseFull,
              })
          .toList(),
    };
    final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filePath = '${dir.path}/silsigan_export_$timestamp.json';
    await File(filePath).writeAsString(jsonString);
    return filePath;
  }

  Future<int> deleteSession(int id) async {
    // Also delete the audio file if it exists
    final session = await getSession(id);
    if (session?.audioPath != null) {
      final file = File(session!.audioPath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
    final db = await database;
    return db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }
}
