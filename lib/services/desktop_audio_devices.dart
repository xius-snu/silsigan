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
    this.isBluetooth = false,
  });

  final String id;
  final String label;
  final bool isDefault;
  final bool isBluetooth;
}

/// Lists input/output devices and pulls native loopback PCM on Windows,
/// macOS, Android (MediaProjection playback capture), and iOS (ReplayKit
/// broadcast). Linux speaker capture uses Pulse monitor sources through
/// `record`.
class DesktopAudioDevices {
  DesktopAudioDevices._();

  static const _channel = MethodChannel('com.silsigan.app/desktop_audio');

  /// Ceiling on one native audio-session reconfiguration. Generous enough for
  /// a real setCategory + setActive + setPreferredInput round trip, short
  /// enough that a wedged session cannot hold the record button hostage.
  static const _applyRouteTimeout = Duration(seconds: 3);

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

  /// Pin capture to [micDeviceId] (null / empty = phone built-in mic) and
  /// route playback to A2DP headphones when connected. Pass [bluetoothMic]
  /// when the chosen input is itself a Bluetooth headset mic — that path
  /// has to use HFP/SCO, which also takes over output.
  static Future<void> applyCaptureRoute({
    String? micDeviceId,
    bool? bluetoothMic,
    bool updateMic = false,
  }) async {
    if (kIsWeb) return;
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    try {
      // Bounded: this reconfigures the native audio session on the platform
      // main thread and sits on the record-start path. A session that stalls
      // must degrade into a wrong route, never a record button that never
      // flips to Stop. The timeout doesn't cancel the native call, it just
      // stops the start path waiting on it.
      await _channel.invokeMethod<void>('applyCaptureRoute', {
        if (updateMic) 'micDeviceId': micDeviceId ?? '',
        if (bluetoothMic != null) 'bluetoothMic': bluetoothMic,
      }).timeout(_applyRouteTimeout);
    } catch (_) {}
  }

  static bool isBluetoothInput(
    String? deviceId,
    List<DesktopAudioDevice> inputs,
  ) {
    if (deviceId == null || deviceId.isEmpty) return false;
    for (final d in inputs) {
      if (d.id == deviceId) return d.isBluetooth;
    }
    return false;
  }

  /// Default / empty selection resolves to the built-in phone mic so a
  /// connected headset cannot silently become the capture source.
  static String? resolvedInputId(
    String? deviceId,
    List<DesktopAudioDevice> inputs,
  ) {
    if (deviceId != null && deviceId.isNotEmpty) return deviceId;
    for (final d in inputs) {
      if (d.isDefault) return d.id;
    }
    for (final d in inputs) {
      if (!d.isBluetooth) return d.id;
    }
    return null;
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
              isBluetooth: item['isBluetooth'] == true,
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
