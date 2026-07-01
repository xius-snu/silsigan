import 'package:flutter/material.dart';
import '../../utils/constants.dart';

/// A subtle animated "listening" placeholder shown while a recording session is
/// warming up — the WebSocket handshake + Soniox model warmup make the FIRST
/// transcription take ~1-2s, and without this an empty panel reads as frozen.
/// Three dots pulse in sequence next to a label.
class ListeningIndicator extends StatefulWidget {
  final String label;
  final Color? color;

  const ListeningIndicator({
    super.key,
    this.label = 'Listening',
    this.color,
  });

  @override
  State<ListeningIndicator> createState() => _ListeningIndicatorState();
}

class _ListeningIndicatorState extends State<ListeningIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppConstants.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 14,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 8),
        for (int i = 0; i < 3; i++)
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              // Phase-shifted triangle wave (0→1→0) per dot for a travelling
              // pulse.
              final t = (_controller.value + i * 0.18) % 1.0;
              final wave = (0.5 - (t - 0.5).abs()) * 2;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.5),
                child: Opacity(
                  opacity: 0.25 + 0.75 * wave,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
