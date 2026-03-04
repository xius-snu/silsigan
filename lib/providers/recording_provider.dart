import 'package:flutter_riverpod/flutter_riverpod.dart';

enum RecordingState { idle, recording, processing, postRecording }

final recordingStateProvider =
    StateProvider<RecordingState>((ref) => RecordingState.idle);
