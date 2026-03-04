import 'package:sqflite/sqflite.dart';
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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            korean_full TEXT NOT NULL,
            vietnamese_full TEXT NOT NULL,
            korean_preview TEXT NOT NULL,
            vietnamese_preview TEXT NOT NULL
          )
        ''');
      },
    );
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

  Future<int> deleteSession(int id) async {
    final db = await database;
    return db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }
}
