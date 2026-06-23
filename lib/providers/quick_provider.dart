import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Quick Mode display state. Unlike the other modes, Quick Mode keeps the
/// transcription and translation as two single growing strings (no history,
/// no saving). Each is the confirmed text plus the current in-progress draft.
/// They reset on the first word of the next press-and-hold.
final quickTranscriptProvider = StateProvider<String>((ref) => '');

final quickTranslationProvider = StateProvider<String>((ref) => '');

/// Whether Quick Mode speaks the translation aloud on release. Defaults ON —
/// Quick Mode is built around hearing the result. Independent of the global
/// [ttsEnabledProvider] the other modes use (which defaults off). Not
/// persisted: resets to on each launch.
final quickTtsEnabledProvider = StateProvider<bool>((ref) => true);
