import 'package:flutter_riverpod/flutter_riverpod.dart';

enum RecordingState { idle, recording, processing, postRecording }

final recordingStateProvider =
    StateProvider<RecordingState>((ref) => RecordingState.idle);

/// The live transcription link dropped mid-session and is being restored.
/// Set a couple of seconds after the drop, so a brief blip shows nothing.
final transcriptionReconnectingProvider = StateProvider<bool>((ref) => false);
