import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/transcript_session.dart';
import '../utils/constants.dart';
import 'user_service.dart';
import 'database_service.dart';

class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  String get _baseUrl => AppConstants.serverBaseUrl;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (UserService.instance.authToken != null)
          'Authorization': 'Bearer ${UserService.instance.authToken}',
      };

  /// Upload a single session to the server (text only, fire-and-forget).
  Future<void> uploadSession(TranscriptSession session) async {
    try {
      // Ensure we have an auth token before uploading
      await UserService.instance.ensureAuthenticated();

      final userId = UserService.instance.userId;
      if (userId == null) return;
      if (UserService.instance.authToken == null) return;

      // Audio deliberately stays local: raw PCM16 WAV runs ~172 MB per hour,
      // which neither the 50 MB request cap nor Postgres storage can absorb.
      // Word timestamps and the title are kilobytes and do sync, so a session
      // opened on another device keeps its name and line-by-line structure.
      final body = json.encode({
        'userId': userId,
        'createdAt': session.createdAt,
        'transcription': session.koreanFull,
        'translation': session.vietnameseFull,
        'transcriptionPreview': session.koreanPreview,
        'translationPreview': session.vietnamesePreview,
        'timestampsJson': session.timestampsJson,
        'title': session.title,
      });

      var response = await http
          .post(
            Uri.parse('$_baseUrl/api/sessions/save'),
            headers: _headers,
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      // If 401, token is stale — refresh and retry once
      if (response.statusCode == 401) {
        debugPrint('Upload got 401, refreshing token and retrying');
        await UserService.instance.refreshToken();
        if (UserService.instance.authToken == null) return;
        response = await http
            .post(
              Uri.parse('$_baseUrl/api/sessions/save'),
              headers: _headers,
              body: body,
            )
            .timeout(const Duration(seconds: 15));
      }

      debugPrint('Upload session response: ${response.statusCode}');
    } catch (e) {
      debugPrint('Upload session error: $e');
    }
  }

  /// Sync: apply remote deletes, download new sessions, patch titles on
  /// existing local rows, upload local-only sessions that are not tombstoned.
  /// Returns true if local history changed (so the UI can refresh).
  Future<bool> syncFromServer() async {
    try {
      await UserService.instance.ensureAuthenticated();

      final userId = UserService.instance.userId;
      if (userId == null) return false;
      if (UserService.instance.authToken == null) return false;

      // Get server session list (metadata only)
      var response = await http
          .post(
            Uri.parse('$_baseUrl/api/sessions/list'),
            headers: _headers,
            body: json.encode({'userId': userId}),
          )
          .timeout(const Duration(seconds: 10));

      // If 401, refresh token and retry once
      if (response.statusCode == 401) {
        await UserService.instance.refreshToken();
        if (UserService.instance.authToken == null) return false;
        response = await http
            .post(
              Uri.parse('$_baseUrl/api/sessions/list'),
              headers: _headers,
              body: json.encode({'userId': userId}),
            )
            .timeout(const Duration(seconds: 10));
      }

      if (response.statusCode != 200) return false;

      final data = json.decode(response.body);
      final serverSessions = (data['sessions'] as List?) ?? [];
      final deletedCreatedAts =
          ((data['deleted'] as List?) ?? []).map((e) => e.toString()).toSet();

      // Get local sessions
      final localSessions = await DatabaseService.instance.getAllSessions();
      final localByCreatedAt = <String, TranscriptSession>{
        for (final s in localSessions) s.createdAt: s,
      };

      bool changed = false;

      // (a) Apply server tombstones to local DB so a delete on another
      // device actually disappears here instead of being re-uploaded.
      for (final createdAt in deletedCreatedAts) {
        if (localByCreatedAt.containsKey(createdAt)) {
          await DatabaseService.instance.deleteSessionByCreatedAt(createdAt);
          localByCreatedAt.remove(createdAt);
          changed = true;
        }
      }

      // (b) Download sessions on server but not local.
      // (c) Patch title on existing local rows (list already returns title,
      // so untitled copies pick it up without a full GET).
      for (final serverSession in serverSessions) {
        final createdAt = serverSession['created_at'] as String;
        if (deletedCreatedAts.contains(createdAt)) continue;
        final local = localByCreatedAt[createdAt];
        if (local == null) {
          await _downloadAndSaveSession(userId, serverSession['id'] as int);
          changed = true;
        } else {
          final serverTitle = serverSession['title'] as String?;
          if (serverTitle != null &&
              serverTitle.isNotEmpty &&
              serverTitle != local.title) {
            await DatabaseService.instance
                .updateSessionTitleByCreatedAt(createdAt, serverTitle);
            changed = true;
          }
        }
      }

      // (d) Upload local sessions not on server, unless tombstoned.
      final serverTimestamps =
          serverSessions.map((s) => s['created_at'] as String).toSet();
      for (final local in localByCreatedAt.values) {
        if (!serverTimestamps.contains(local.createdAt) &&
            !deletedCreatedAts.contains(local.createdAt)) {
          uploadSession(local);
        }
      }

      return changed;
    } catch (e) {
      debugPrint('Sync error: $e');
      return false;
    }
  }

  Future<void> _downloadAndSaveSession(
      String userId, int serverSessionId) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/sessions/get'),
            headers: _headers,
            body: json.encode({'userId': userId, 'sessionId': serverSessionId}),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) return;

      final data = json.decode(response.body);
      final session = data['session'];
      if (session == null) return;

      final createdAt = session['created_at'] as String;
      final title = session['title'] as String?;
      final koreanFull = session['transcription'] as String;
      final vietnameseFull = session['translation'] as String;
      final koreanPreview = session['transcription_preview'] as String;
      final vietnamesePreview = session['translation_preview'] as String;
      final timestampsJson = session['timestamps_json'] as String?;

      // Production-safe: if the local row already exists (untitled copy,
      // race with a just-saved session), patch title and text instead of
      // inserting a duplicate. audio_path stays on the original row.
      final existing =
          await DatabaseService.instance.getSessionByCreatedAt(createdAt);
      if (existing != null) {
        await DatabaseService.instance.updateSessionFromServer(
          createdAt: createdAt,
          koreanFull: koreanFull,
          vietnameseFull: vietnameseFull,
          koreanPreview: koreanPreview,
          vietnamesePreview: vietnamesePreview,
          timestampsJson: timestampsJson,
          title: title,
        );
        return;
      }

      final newSession = TranscriptSession(
        createdAt: createdAt,
        koreanFull: koreanFull,
        vietnameseFull: vietnameseFull,
        koreanPreview: koreanPreview,
        vietnamesePreview: vietnamesePreview,
        timestampsJson: timestampsJson,
        title: title,
        // audioPath stays null — audio never leaves the device that recorded
        // it, so a synced session simply shows no player elsewhere.
      );

      await DatabaseService.instance.insertSession(newSession);
    } catch (e) {
      debugPrint('Download session error: $e');
    }
  }

  /// Delete a session from the server by its created_at timestamp.
  Future<void> deleteFromServer(String createdAt) async {
    try {
      await UserService.instance.ensureAuthenticated();

      final userId = UserService.instance.userId;
      if (userId == null) return;
      if (UserService.instance.authToken == null) return;

      await http
          .post(
            Uri.parse('$_baseUrl/api/sessions/delete'),
            headers: _headers,
            body: json.encode({'userId': userId, 'createdAt': createdAt}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Delete from server error: $e');
    }
  }
}
