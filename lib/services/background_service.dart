import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Top-level callback required by flutter_foreground_task.
@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_MinimalTaskHandler());
}

/// Minimal handler — we don't run any logic in the service isolate.
/// The foreground service just keeps the app process alive.
class _MinimalTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

class BackgroundService {
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    if (!Platform.isAndroid) {
      _initialized = true;
      return;
    }

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'silsigan_recording',
        channelName: 'Recording Service',
        channelDescription: 'Keeps recording active in background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  static Future<void> startRecordingService() async {
    if (!Platform.isAndroid) return;
    if (!_initialized) init();

    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Silsigan',
      notificationText: 'Recording in progress...',
      callback: _startCallback,
    );
  }

  static Future<void> stopRecordingService() async {
    if (!Platform.isAndroid) return;

    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // Service might already be stopped
    }
  }
}
