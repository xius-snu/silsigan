import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/desktop.dart';

enum DesktopAudioSource { microphone, speaker, both }

class DesktopAudioSettings {
  const DesktopAudioSettings({
    this.source = DesktopAudioSource.microphone,
    this.micDeviceId,
    this.speakerDeviceId,
  });

  final DesktopAudioSource source;
  final String? micDeviceId;
  final String? speakerDeviceId;

  bool get captureMic => source != DesktopAudioSource.speaker;
  bool get captureSpeaker => source != DesktopAudioSource.microphone;

  DesktopAudioSettings copyWith({
    DesktopAudioSource? source,
    String? micDeviceId,
    String? speakerDeviceId,
    bool clearMicDevice = false,
    bool clearSpeakerDevice = false,
  }) {
    return DesktopAudioSettings(
      source: source ?? this.source,
      micDeviceId: clearMicDevice ? null : (micDeviceId ?? this.micDeviceId),
      speakerDeviceId:
          clearSpeakerDevice ? null : (speakerDeviceId ?? this.speakerDeviceId),
    );
  }
}

final desktopAudioSettingsProvider =
    StateProvider<DesktopAudioSettings>((ref) => const DesktopAudioSettings());

const _sourceKey = 'desktop_audio_source';
const _micKey = 'desktop_audio_mic_id';
const _speakerKey = 'desktop_audio_speaker_id';
const _iosResetKey = 'desktop_audio_ios_reset_v1';

Future<DesktopAudioSettings> loadSavedDesktopAudioSettings() async {
  final prefs = await SharedPreferences.getInstance();
  // The selector was hidden on iPhone / iPad from 1.1.1 until 1.1.4+79, and
  // capture ran on the built-in mic whatever was saved. A Speaker / Both or
  // headset-mic choice from 1.0.15–1.0.17 must not quietly come back (with a
  // surprise Start Broadcast sheet) now that it's visible again.
  if (isIOSPlatform && !(prefs.getBool(_iosResetKey) ?? false)) {
    await prefs.remove(_sourceKey);
    await prefs.remove(_micKey);
    await prefs.remove(_speakerKey);
    await prefs.setBool(_iosResetKey, true);
  }
  final name = prefs.getString(_sourceKey);
  var source = DesktopAudioSource.values.firstWhere(
    (s) => s.name == name,
    orElse: () => DesktopAudioSource.microphone,
  );
  // A platform without speaker capture ignores a stale Speaker / Both pref.
  if (!desktopSpeakerCaptureSupported &&
      source != DesktopAudioSource.microphone) {
    source = DesktopAudioSource.microphone;
  }
  return DesktopAudioSettings(
    source: source,
    micDeviceId: prefs.getString(_micKey),
    speakerDeviceId: prefs.getString(_speakerKey),
  );
}

Future<void> saveDesktopAudioSettings(DesktopAudioSettings settings) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_sourceKey, settings.source.name);
  if (settings.micDeviceId == null || settings.micDeviceId!.isEmpty) {
    await prefs.remove(_micKey);
  } else {
    await prefs.setString(_micKey, settings.micDeviceId!);
  }
  if (settings.speakerDeviceId == null || settings.speakerDeviceId!.isEmpty) {
    await prefs.remove(_speakerKey);
  } else {
    await prefs.setString(_speakerKey, settings.speakerDeviceId!);
  }
}
