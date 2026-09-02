import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<DesktopAudioSettings> loadSavedDesktopAudioSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final name = prefs.getString(_sourceKey);
  final source = DesktopAudioSource.values.firstWhere(
    (s) => s.name == name,
    orElse: () => DesktopAudioSource.microphone,
  );
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
