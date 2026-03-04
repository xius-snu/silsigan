import 'package:flutter/material.dart';
import '../../providers/recording_provider.dart';
import '../../utils/constants.dart';

class RecordButton extends StatelessWidget {
  final RecordingState state;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const RecordButton({
    super.key,
    required this.state,
    required this.onStart,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final isRecording = state == RecordingState.recording ||
        state == RecordingState.processing;

    return GestureDetector(
      onTap: isRecording ? onStop : onStart,
      child: Container(
        width: AppConstants.micButtonSize,
        height: AppConstants.micButtonSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isRecording ? Colors.red : AppConstants.micButtonColor,
        ),
        child: Icon(
          isRecording ? Icons.stop_rounded : Icons.mic,
          size: AppConstants.micIconSize,
          color: Colors.white,
        ),
      ),
    );
  }
}
