import 'dart:async';
import 'package:flutter/material.dart';
import '../../providers/recording_provider.dart';

class StatusBar extends StatefulWidget {
  final RecordingState state;

  const StatusBar({super.key, required this.state});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  // A discrete timer blink instead of a vsync AnimationController: a repeating
  // controller forces a frame every refresh interval (120Hz on recent phones)
  // for the entire recording session just to pulse a 10px dot. The timer costs
  // 2 tiny rebuilds per second instead.
  Timer? _blinkTimer;
  bool _dotVisible = true;

  bool get _shouldBlink =>
      widget.state == RecordingState.recording ||
      widget.state == RecordingState.processing;

  @override
  void initState() {
    super.initState();
    _syncBlinkTimer();
  }

  @override
  void didUpdateWidget(StatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBlinkTimer();
  }

  void _syncBlinkTimer() {
    if (_shouldBlink && _blinkTimer == null) {
      _blinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() => _dotVisible = !_dotVisible);
      });
    } else if (!_shouldBlink && _blinkTimer != null) {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      _dotVisible = true;
    }
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.state == RecordingState.idle ||
        widget.state == RecordingState.postRecording) {
      return const SizedBox.shrink();
    }

    final isRecording = widget.state == RecordingState.recording;
    final label = isRecording ? 'Recording' : 'Saving...';
    final color = isRecording ? Colors.red : Colors.amber.shade800;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: Opacity(
              opacity: _dotVisible ? 1.0 : 0.4,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
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
