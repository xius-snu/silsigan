import 'package:flutter/material.dart';
import '../../utils/constants.dart';

/// People icon that toggles speaker diarization ("who said what" labels).
/// Diarization is configured on the Soniox session at connect time, so the
/// toggle is non-interactive (dimmed) while recording.
class DiarizationToggleButton extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final bool interactive;
  final double iconSize;

  const DiarizationToggleButton({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
    this.interactive = true,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: interactive ? 1.0 : 0.4,
      child: GestureDetector(
        onTap: interactive ? () => onEnabledChanged(!enabled) : null,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Tooltip(
            message: 'Speaker labels',
            child: Icon(
              enabled ? Icons.people_alt : Icons.people_alt_outlined,
              size: iconSize,
              color: enabled
                  ? AppConstants.textPrimary
                  : AppConstants.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
