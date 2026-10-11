import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Finds a saved session's recording on this device.
///
/// A session stores the absolute path its WAV was written to. On iOS that
/// path runs through the app's data container, and iOS can give the
/// container a new path when the app is updated or restored. The recordings
/// move with it and stay in the documents directory, but every path stored
/// before the move points nowhere: those sessions showed 00:00 and their play
/// button did nothing. Recordings have always been saved straight into the
/// documents directory, so one that isn't at its stored path is looked up
/// there by file name.
class SessionAudioFiles {
  SessionAudioFiles._();

  static Future<Directory>? _documents;

  /// Only names this app gives recordings are looked up. On Windows the
  /// documents directory is the user's own Documents folder, and a session
  /// delete must never reach a file the app didn't write.
  static final _recordingName = RegExp(r'^session_\d+\.wav$');

  /// The recording's path as it is now, or null when there is none or the
  /// file is gone.
  static Future<String?> resolve(String? storedPath) async {
    if (storedPath == null || storedPath.isEmpty) return null;
    try {
      if (await File(storedPath).exists()) return storedPath;
    } catch (_) {}
    final name = fileNameOf(storedPath);
    if (!_recordingName.hasMatch(name)) return null;
    try {
      final dir = await (_documents ??= getApplicationDocumentsDirectory());
      final moved = '${dir.path}/$name';
      if (await File(moved).exists()) return moved;
    } catch (_) {
      _documents = null;
    }
    return null;
  }

  /// The last segment of [path], whichever separator wrote it.
  static String fileNameOf(String path) {
    final cut = path.lastIndexOf(RegExp(r'[/\\]'));
    return cut < 0 ? path : path.substring(cut + 1);
  }
}
