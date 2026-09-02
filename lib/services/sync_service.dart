import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/transcript_session.dart';
import '../utils/constants.dart';
import '../utils/session_sync.dart';
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

  Future<bool>? _inFlight;

  /// Upload a single session to the server (text only). Returns true when
  /// the server accepted it (including "already deleted" which is success
  /// from this device's point of view).
  Future<bool> uploadSession(TranscriptSession session) async {
    try {
      await UserService.instance.ensureAuthenticated();

      final userId = UserService.instance.userId;
      if (userId == null) return false;
      if (UserService.instance.authToken == null) return false;

      if (await DatabaseService.instance.isTombstoned(session.createdAt)) {
        return await deleteFromServer(session.createdAt);
      }

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
        'updatedAt': session.updatedAt ?? session.createdAt,
      });

      var response = await _postWithRetry(
        '/api/sessions/save',
        body,
        timeout: const Duration(seconds: 15),
      );
      if (response == null) return false;

      if (response.statusCode == 200) {
        try {
          final data = json.decode(response.body);
          if (data is Map && data['deleted'] == true) {
            await DatabaseService.instance
                .deleteSessionByCreatedAt(session.createdAt, fromServer: true);
          }
        } catch (_) {}
        return true;
      }
      debugPrint('Upload session response: ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('Upload session error: $e');
      return false;
    }
  }

  /// Sync: apply remote deletes, download new sessions, patch titles on
  /// existing local rows, upload local-only sessions that are not tombstoned.
  /// Returns true if local history changed (so the UI can refresh).
  Future<bool> syncFromServer() {
    return _inFlight ??= _syncFromServerBody().whenComplete(() {
      _inFlight = null;
    });
  }

  Future<bool> _syncFromServerBody() async {
    try {
      await UserService.instance.ensureAuthenticated();

      final userId = UserService.instance.userId;
      if (userId == null) return false;
      if (UserService.instance.authToken == null) return false;

      final db = DatabaseService.instance;

      // Push local deletes first so a device that still holds the row cannot
      // win a race against this device's tombstone.
      final unsyncedDeletes = await db.getUnsyncedTombstones();
      final acked = <String>[];
      for (final createdAt in unsyncedDeletes) {
        if (await deleteFromServer(createdAt)) {
          acked.add(createdAt);
        }
      }
      if (acked.isNotEmpty) {
        await db.markTombstonesSynced(acked);
      }

      var response = await _postWithRetry(
        '/api/sessions/list',
        json.encode({'userId': userId}),
        timeout: const Duration(seconds: 10),
      );
      if (response == null || response.statusCode != 200) return false;

      final data = json.decode(response.body);
      final serverSessions = (data['sessions'] as List?) ?? [];
      final deletedCreatedAts =
          ((data['deleted'] as List?) ?? []).map((e) => e.toString()).toSet();

      final localSessions = await db.getAllSessions();
      final localByCreatedAt = <String, TranscriptSession>{
        for (final s in localSessions) s.createdAt: s,
      };
      final localTombstones = await db.getTombstoneCreatedAts();

      bool changed = false;

      // Apply server tombstones to local DB so a delete on another device
      // actually disappears here instead of being re-uploaded.
      for (final createdAt in deletedCreatedAts) {
        if (localByCreatedAt.containsKey(createdAt) ||
            !localTombstones.contains(createdAt)) {
          if (localByCreatedAt.containsKey(createdAt)) {
            await db.deleteSessionByCreatedAt(createdAt, fromServer: true);
            localByCreatedAt.remove(createdAt);
            changed = true;
          } else {
            await db.addTombstone(createdAt, synced: true);
          }
          localTombstones.add(createdAt);
        }
      }

      // Drop any local row that this device already tombstoned (covers a
      // delete that raced an in-flight download).
      for (final createdAt in localTombstones) {
        if (localByCreatedAt.containsKey(createdAt)) {
          await db.deleteSessionByCreatedAt(createdAt);
          localByCreatedAt.remove(createdAt);
          changed = true;
        }
      }

      final toUpload = <TranscriptSession>[];

      for (final serverSession in serverSessions) {
        final createdAt = asString(serverSession['created_at']);
        if (createdAt == null || createdAt.isEmpty) continue;
        if (deletedCreatedAts.contains(createdAt) ||
            localTombstones.contains(createdAt)) {
          continue;
        }
        final local = localByCreatedAt[createdAt];
        final plan = planSessionSync(
          localExists: local != null,
          tombstoned: false,
          localTitle: local?.title,
          serverTitle: asString(serverSession['title']),
          localUpdatedAt: parseSyncTime(local?.updatedAt ?? local?.createdAt),
          serverUpdatedAt: parseSyncTime(asString(serverSession['updated_at'])),
        );
        switch (plan.action) {
          case SessionSyncAction.skip:
            break;
          case SessionSyncAction.download:
            final id = asInt(serverSession['id']);
            if (id == null) continue;
            if (await db.isTombstoned(createdAt)) continue;
            await _downloadAndSaveSession(
              userId,
              id,
              fallbackTitle: asString(serverSession['title']),
              fallbackUpdatedAt: asString(serverSession['updated_at']),
            );
            changed = true;
            break;
          case SessionSyncAction.patchLocalTitle:
            final title = plan.titleToPatch;
            if (title != null) {
              await db.updateSessionTitleByCreatedAt(
                createdAt,
                title,
                updatedAt: asString(serverSession['updated_at']) ??
                    DateTime.now().toUtc().toIso8601String(),
              );
              changed = true;
            }
            break;
          case SessionSyncAction.upload:
            if (local != null) toUpload.add(local);
            break;
        }
      }

      final serverTimestamps = <String>{};
      for (final s in serverSessions) {
        final createdAt = asString(s['created_at']);
        if (createdAt != null) serverTimestamps.add(createdAt);
      }
      for (final local in localByCreatedAt.values) {
        if (!serverTimestamps.contains(local.createdAt) &&
            !localTombstones.contains(local.createdAt) &&
            !deletedCreatedAts.contains(local.createdAt)) {
          toUpload.add(local);
        }
      }

      for (final session in toUpload) {
        if (await db.isTombstoned(session.createdAt)) continue;
        await uploadSession(session);
      }

      return changed;
    } catch (e) {
      debugPrint('Sync error: $e');
      return false;
    }
  }

  Future<void> _downloadAndSaveSession(
    String userId,
    int serverSessionId, {
    String? fallbackTitle,
    String? fallbackUpdatedAt,
  }) async {
    try {
      final response = await _postWithRetry(
        '/api/sessions/get',
        json.encode({'userId': userId, 'sessionId': serverSessionId}),
        timeout: const Duration(seconds: 60),
      );
      if (response == null || response.statusCode != 200) return;

      final data = json.decode(response.body);
      final session = data['session'];
      if (session == null) return;

      final createdAt = asString(session['created_at']);
      if (createdAt == null || createdAt.isEmpty) return;
      if (await DatabaseService.instance.isTombstoned(createdAt)) return;

      final title = nonemptyTitle(asString(session['title'])) ??
          nonemptyTitle(fallbackTitle);
      final koreanFull = asString(session['transcription']) ?? '';
      final vietnameseFull = asString(session['translation']) ?? '';
      final koreanPreview = asString(session['transcription_preview']) ?? '';
      final vietnamesePreview = asString(session['translation_preview']) ?? '';
      final timestampsJson = asString(session['timestamps_json']);
      final updatedAt =
          asString(session['updated_at']) ?? fallbackUpdatedAt ?? createdAt;

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
          updatedAt: updatedAt,
        );
        return;
      }

      if (await DatabaseService.instance.isTombstoned(createdAt)) return;

      await DatabaseService.instance.insertSession(
        TranscriptSession(
          createdAt: createdAt,
          koreanFull: koreanFull,
          vietnameseFull: vietnameseFull,
          koreanPreview: koreanPreview,
          vietnamesePreview: vietnamesePreview,
          timestampsJson: timestampsJson,
          title: title,
          updatedAt: updatedAt,
        ),
      );
    } catch (e) {
      debugPrint('Download session error: $e');
    }
  }

  /// Delete a session from the server by its created_at timestamp.
  /// Returns true when the server acknowledged the tombstone.
  Future<bool> deleteFromServer(String createdAt) async {
    try {
      await UserService.instance.ensureAuthenticated();

      final userId = UserService.instance.userId;
      if (userId == null) return false;
      if (UserService.instance.authToken == null) return false;

      final response = await _postWithRetry(
        '/api/sessions/delete',
        json.encode({'userId': userId, 'createdAt': createdAt}),
        timeout: const Duration(seconds: 10),
      );
      return response != null && response.statusCode == 200;
    } catch (e) {
      debugPrint('Delete from server error: $e');
      return false;
    }
  }

  Future<http.Response?> _postWithRetry(
    String path,
    String body, {
    required Duration timeout,
  }) async {
    var response = await http
        .post(
          Uri.parse('$_baseUrl$path'),
          headers: _headers,
          body: body,
        )
        .timeout(timeout);

    if (response.statusCode == 401) {
      debugPrint('Sync got 401 on $path, refreshing token and retrying');
      await UserService.instance.refreshToken();
      if (UserService.instance.authToken == null) return null;
      response = await http
          .post(
            Uri.parse('$_baseUrl$path'),
            headers: _headers,
            body: body,
          )
          .timeout(timeout);
    }
    return response;
  }
}
