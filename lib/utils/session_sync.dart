// Pure merge rules for cloud session sync. Kept free of I/O so the
// last-write-wins / tombstone cases can be unit-tested.

enum SessionSyncAction {
  /// Nothing to do for this row.
  skip,

  /// Server has it, this device does not — pull the full session.
  /// Also used when titles match but the server row is newer (a text
  /// edit on another device); the list payload has no body, so we
  /// download and patch in place.
  download,

  /// This device's title or text is newer — push the full session.
  upload,

  /// Server has a title this device is missing (or a newer rename) — patch.
  patchLocalTitle,
}

class SessionSyncPlan {
  const SessionSyncPlan({required this.action, this.titleToPatch});

  final SessionSyncAction action;
  final String? titleToPatch;
}

String? nonemptyTitle(String? title) {
  final t = title?.trim() ?? '';
  return t.isEmpty ? null : t;
}

DateTime? parseSyncTime(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

/// True when [local] should win a title/content conflict against [server].
/// A missing server timestamp is treated as older so a titled local copy
/// backfills sessions saved before the server stored titles.
bool localIsNewer(DateTime? local, DateTime? server) {
  if (server == null) return true;
  if (local == null) return false;
  return !local.isBefore(server);
}

/// True when both timestamps are missing (legacy rows) or name the same
/// instant. Used to skip a same-title pair that has not actually changed.
bool sameSyncTime(DateTime? a, DateTime? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  return !a.isBefore(b) && !b.isBefore(a);
}

SessionSyncPlan planSessionSync({
  required bool localExists,
  required bool tombstoned,
  String? localTitle,
  String? serverTitle,
  DateTime? localUpdatedAt,
  DateTime? serverUpdatedAt,
}) {
  if (tombstoned) {
    return const SessionSyncPlan(action: SessionSyncAction.skip);
  }
  if (!localExists) {
    return const SessionSyncPlan(action: SessionSyncAction.download);
  }

  final localT = nonemptyTitle(localTitle);
  final serverT = nonemptyTitle(serverTitle);
  if (localT == serverT) {
    // Titles matching used to mean "nothing to do", which dropped text
    // edits: the list endpoint has no body, only updated_at. Same title
    // + newer local timestamp → upload; newer server → download.
    if (sameSyncTime(localUpdatedAt, serverUpdatedAt)) {
      return const SessionSyncPlan(action: SessionSyncAction.skip);
    }
    if (localIsNewer(localUpdatedAt, serverUpdatedAt)) {
      return const SessionSyncPlan(action: SessionSyncAction.upload);
    }
    return const SessionSyncPlan(action: SessionSyncAction.download);
  }

  if (serverT == null) {
    return const SessionSyncPlan(action: SessionSyncAction.upload);
  }
  if (localT == null) {
    return SessionSyncPlan(
      action: SessionSyncAction.patchLocalTitle,
      titleToPatch: serverT,
    );
  }

  if (localIsNewer(localUpdatedAt, serverUpdatedAt)) {
    return const SessionSyncPlan(action: SessionSyncAction.upload);
  }
  return SessionSyncPlan(
    action: SessionSyncAction.patchLocalTitle,
    titleToPatch: serverT,
  );
}

int? asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? asString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}
