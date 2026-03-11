import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Speaker ID per transcription history line (aligned with koreanHistoryProvider).
final transcriptionSpeakersProvider = StateProvider<List<String?>>((ref) => []);

/// Speaker ID per translation history line (aligned with vietnameseHistoryProvider).
final translationSpeakersProvider = StateProvider<List<String?>>((ref) => []);

/// Speaker ID for the current live draft (while someone is speaking).
final draftSpeakerProvider = StateProvider<String?>((ref) => null);

/// Format a Soniox speaker ID ("0", "1", ...) into a display label.
String speakerLabel(String speaker) {
  final num = int.tryParse(speaker);
  return num != null ? 'Speaker ${num + 1}' : 'Speaker $speaker';
}
