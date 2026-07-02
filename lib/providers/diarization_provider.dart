import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Speaker diarization toggle (line-by-line, split, and transcription modes).
/// Applies at connect time — the Soniox session is configured with
/// `enable_speaker_diarization`, so mid-recording changes don't take effect
/// (the toggle is disabled while recording).
final diarizationEnabledProvider = StateProvider<bool>((ref) => false);

/// Per-line speaker attribution, index-aligned with [koreanHistoryProvider]
/// (one entry per line in line-by-line mode, per paragraph in split /
/// transcription). null = unattributed (diarization off, or no speaker data
/// for that line). Display-only — not persisted to autosave or saved sessions.
final speakerHistoryProvider = StateProvider<List<int?>>((ref) => []);

Future<bool> loadSavedDiarizationEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('diarization_enabled') ?? false;
}

Future<void> saveDiarizationEnabled(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('diarization_enabled', enabled);
}
