import 'package:flutter/material.dart';
import '../../providers/recording_provider.dart';

class StatusBar extends StatelessWidget {
  final RecordingState state;

  const StatusBar({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    if (state == RecordingState.idle || state == RecordingState.postRecording) {
      return const SizedBox.shrink();
    }

    final isRecording = state == RecordingState.recording;
    final label = isRecording ? 'Recording' : 'Processing';
    final color = isRecording ? Colors.red : Colors.amber.shade700;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
