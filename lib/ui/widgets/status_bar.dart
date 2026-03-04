import 'package:flutter/material.dart';
import '../../providers/recording_provider.dart';

class StatusBar extends StatefulWidget {
  final RecordingState state;

  const StatusBar({super.key, required this.state});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (_shouldAnimate) {
      _pulseController.repeat(reverse: true);
    }
  }

  bool get _shouldAnimate =>
      widget.state == RecordingState.recording ||
      widget.state == RecordingState.processing;

  @override
  void didUpdateWidget(StatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldAnimate && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!_shouldAnimate && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.state == RecordingState.idle ||
        widget.state == RecordingState.postRecording) {
      return const SizedBox.shrink();
    }

    final isRecording = widget.state == RecordingState.recording;
    final label = isRecording ? 'Recording' : 'Processing';
    final color = isRecording ? Colors.red : Colors.amber.shade800;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Opacity(
                opacity: _pulseAnimation.value,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
              );
            },
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
