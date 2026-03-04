import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../providers/recording_provider.dart';
import '../../utils/constants.dart';

class RecordButton extends StatefulWidget {
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
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    _scaleController.forward();
  }

  void _onTapUp(TapUpDetails _) {
    _scaleController.reverse();
  }

  void _onTapCancel() {
    _scaleController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = widget.state == RecordingState.recording ||
        widget.state == RecordingState.processing;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: () {
        HapticFeedback.mediumImpact();
        if (isRecording) {
          widget.onStop();
        } else {
          widget.onStart();
        }
      },
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: child,
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeInOut,
          width: AppConstants.micButtonSize,
          height: AppConstants.micButtonSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isRecording ? Colors.red : AppConstants.micButtonColor,
            boxShadow: [
              BoxShadow(
                color: isRecording
                    ? Colors.red.withOpacity(0.3)
                    : Colors.black.withOpacity(0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            isRecording ? Icons.stop_rounded : Icons.mic,
            size: AppConstants.micIconSize,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
