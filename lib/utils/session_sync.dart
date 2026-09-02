// Pure merge rules for cloud session sync. Kept free of I/O so the
// last-write-wins / tombstone cases can be unit-tested.

enum SessionSyncAction {
  /// Nothing to do for this row.
  skip,

  /// Server has it, this device does not — pull the full session.
  download,

  /// This device's title (or newer edit) is missing on the server — push.
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

/// True when [local] should win a title conflict against [server].
/// A missing server timestamp is treated as older so a titled local copy
/// backfills sessions saved before the server stored titles.
bool localIsNewer(DateTime? local, DateTime? server) {
  if (server == null) return true;
  if (local == null) return false;
  return !local.isBefore(server);
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
    return const SessionSyncPlan(action: SessionSyncAction.skip);
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
