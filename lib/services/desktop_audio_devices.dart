import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:record/record.dart' as rec;
import '../utils/desktop.dart';

class DesktopAudioDevice {
  const DesktopAudioDevice({
    required this.id,
    required this.label,
    this.isDefault = false,
  });

  final String id;
  final String label;
  final bool isDefault;
}

/// Lists input/output devices and pulls native loopback PCM on Windows,
/// macOS, Android (MediaProjection playback capture), and iOS (ReplayKit
/// broadcast). Linux speaker capture uses Pulse monitor sources through
/// `record`.
class DesktopAudioDevices {
  DesktopAudioDevices._();

  static const _channel = MethodChannel('com.silsigan.app/desktop_audio');

  static bool get nativeLoopbackSupported {
    if (kIsWeb) return false;
    return Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isAndroid ||
        Platform.isIOS;
  }

  static Future<List<DesktopAudioDevice>> listInputs() async {
    if (nativeLoopbackSupported) {
      final listed = await _listFromNative('inputs');
      if (listed.isNotEmpty) return listed;
    }
    final recorder = rec.AudioRecorder();
    try {
      final devices = await recorder.listInputDevices();
      return [
        for (final d in devices)
          DesktopAudioDevice(id: d.id, label: d.label.isEmpty ? d.id : d.label),
      ];
    } finally {
      await recorder.dispose();
    }
  }

  static Future<List<DesktopAudioDevice>> listOutputs() async {
    if (nativeLoopbackSupported) {
      return _listFromNative('outputs');
    }
    if (!kIsWeb && Platform.isLinux) {
      return _listLinuxMonitors();
    }
    return const [];
  }

  static Future<void> startLoopback({String? deviceId}) async {
    if (!nativeLoopbackSupported) {
      throw UnsupportedError(
          'Native loopback is not available on this platform');
    }
    await _channel.invokeMethod<void>('startLoopback', {
      if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
    });
  }

  static Future<void> stopLoopback() async {
    if (!nativeLoopbackSupported) return;
    try {
      await _channel.invokeMethod<void>('stopLoopback');
    } catch (_) {}
  }

  static Future<Uint8List> readLoopback() async {
    if (!nativeLoopbackSupported) return Uint8List(0);
    final bytes = await _channel.invokeMethod<Uint8List>('readLoopback');
    return bytes ?? Uint8List(0);
  }

  static Future<List<DesktopAudioDevice>> _listFromNative(String key) async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('listDevices');
      if (raw is! Map) return const [];
      final list = raw[key];
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map)
            DesktopAudioDevice(
              id: '${item['id'] ?? ''}',
              label: '${item['label'] ?? item['id'] ?? ''}',
              isDefault: item['isDefault'] == true,
            ),
      ].where((d) => d.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<List<DesktopAudioDevice>> _listLinuxMonitors() async {
    if (!desktopSpeakerCaptureSupported) return const [];
    try {
      final result = await Process.run('pactl', ['list', 'sources']);
      if (result.exitCode != 0) return const [];
      final lines = (result.stdout as String).split('\n');
      final devices = <DesktopAudioDevice>[];
      String? name;
      String? description;
      void flush() {
        final id = name;
        if (id == null || id.isEmpty) return;
        final desc = description ?? id;
        final isMonitor = id.endsWith('.monitor') ||
            desc.toLowerCase().startsWith('monitor of');
        if (!isMonitor) return;
        var label = desc;
        const prefix = 'Monitor of ';
        if (label.startsWith(prefix)) {
          label = label.substring(prefix.length);
        }
        devices.add(DesktopAudioDevice(id: id, label: label));
        name = null;
        description = null;
      }

      for (final line in lines) {
        if (line.startsWith('Source #')) {
          flush();
        } else if (line.trimLeft().startsWith('Name:')) {
          name = line.split(':').skip(1).join(':').trim();
        } else if (line.trimLeft().startsWith('Description:')) {
          description = line.split(':').skip(1).join(':').trim();
        }
      }
      flush();
      return devices;
    } catch (_) {
      return const [];
    }
  }
}
