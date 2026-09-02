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
      version: 6,
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
            title TEXT,
            updated_at TEXT
          )
        ''');
        await db.execute(
          'CREATE UNIQUE INDEX idx_sessions_created_at ON sessions(created_at)',
        );
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
        await db.execute('''
          CREATE TABLE session_tombstones (
            created_at TEXT PRIMARY KEY,
            deleted_at TEXT NOT NULL,
            synced INTEGER NOT NULL DEFAULT 0
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
        if (oldVersion < 6) {
          await db.execute(
            'ALTER TABLE sessions ADD COLUMN updated_at TEXT',
          );
          await db.execute('''
            CREATE TABLE IF NOT EXISTS session_tombstones (
              created_at TEXT PRIMARY KEY,
              deleted_at TEXT NOT NULL,
              synced INTEGER NOT NULL DEFAULT 0
            )
          ''');
          // Keep the newest row when the same created_at was inserted twice
          // (sync without a unique key), then lock the identity going forward.
          await db.execute('''
            DELETE FROM sessions WHERE id NOT IN (
              SELECT MAX(id) FROM sessions GROUP BY created_at
            )
          ''');
          await db.execute(
            'CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_created_at '
            'ON sessions(created_at)',
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
    final maps = await db.rawQuery('''
      SELECT s.* FROM sessions s
      WHERE s.created_at NOT IN (SELECT created_at FROM session_tombstones)
      ORDER BY s.created_at DESC
    ''');
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
    final values = session.toMap();
    values['updated_at'] ??=
        session.updatedAt ?? DateTime.now().toUtc().toIso8601String();
    try {
      return await db.insert('sessions', values);
    } catch (_) {
      // Unique created_at — another sync flight inserted first. Patch the
      // cloud fields and keep the existing row (and its local audio_path).
      await updateSessionFromServer(
        createdAt: session.createdAt,
        koreanFull: session.koreanFull,
        vietnameseFull: session.vietnameseFull,
        koreanPreview: session.koreanPreview,
        vietnamesePreview: session.vietnamesePreview,
        timestampsJson: session.timestampsJson,
        title: session.title,
        updatedAt: session.updatedAt ?? values['updated_at'] as String?,
      );
      final existing = await getSessionByCreatedAt(session.createdAt);
      return existing?.id ?? 0;
    }
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
    String createdAt,
    String title, {
    String? updatedAt,
  }) async {
    final db = await database;
    await db.update(
      'sessions',
      {
        'title': title,
        'updated_at': updatedAt ?? DateTime.now().toUtc().toIso8601String(),
      },
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
    String? updatedAt,
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
    if (updatedAt != null) {
      values['updated_at'] = updatedAt;
    }
    await db.update(
      'sessions',
      values,
      where: 'created_at = ?',
      whereArgs: [createdAt],
    );
  }

  Future<void> deleteSessionByCreatedAt(
    String createdAt, {
    bool fromServer = false,
  }) async {
    await addTombstone(createdAt, synced: fromServer);
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

  Future<void> addTombstone(String createdAt, {bool synced = false}) async {
    final db = await database;
    await db.rawInsert(
      '''
      INSERT INTO session_tombstones (created_at, deleted_at, synced)
      VALUES (?, ?, ?)
      ON CONFLICT(created_at) DO UPDATE SET
        synced = CASE
          WHEN session_tombstones.synced = 1 OR excluded.synced = 1 THEN 1
          ELSE 0
        END
      ''',
      [
        createdAt,
        DateTime.now().toUtc().toIso8601String(),
        synced ? 1 : 0,
      ],
    );
  }

  Future<Set<String>> getTombstoneCreatedAts() async {
    final db = await database;
    final maps = await db.query('session_tombstones', columns: ['created_at']);
    return maps.map((m) => m['created_at'] as String).toSet();
  }

  Future<List<String>> getUnsyncedTombstones() async {
    final db = await database;
    final maps = await db.query(
      'session_tombstones',
      columns: ['created_at'],
      where: 'synced = 0',
    );
    return maps.map((m) => m['created_at'] as String).toList();
  }

  Future<bool> isTombstoned(String createdAt) async {
    final db = await database;
    final maps = await db.query(
      'session_tombstones',
      columns: ['created_at'],
      where: 'created_at = ?',
      whereArgs: [createdAt],
      limit: 1,
    );
    return maps.isNotEmpty;
  }

  Future<void> markTombstonesSynced(Iterable<String> createdAts) async {
    if (createdAts.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final createdAt in createdAts) {
      batch.update(
        'session_tombstones',
        {'synced': 1},
        where: 'created_at = ?',
        whereArgs: [createdAt],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> getSessionCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM sessions');
    return (result.first['cnt'] as int?) ?? 0;
  }

  Future<void> updateSessionTitle(int id, String title,
      {String? updatedAt}) async {
    final db = await database;
    await db.update(
      'sessions',
      {
        'title': title,
        'updated_at': updatedAt ?? DateTime.now().toUtc().toIso8601String(),
      },
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
    final session = await getSession(id);
    if (session != null) {
      await addTombstone(session.createdAt);
    }
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
