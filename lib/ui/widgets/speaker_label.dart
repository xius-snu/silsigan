import 'package:flutter/material.dart';
import '../../utils/constants.dart';

/// Small "SPEAKER N" subtitle shown above a transcript line/paragraph when
/// diarization has detected multiple speakers. Each speaker gets a stable
/// distinct color. Excluded from text selection so drag-copied transcripts
/// stay clean.
class SpeakerLabel extends StatelessWidget {
  final int speaker;

  const SpeakerLabel(this.speaker, {super.key});

  static Color colorFor(int speaker) {
    const colors = AppConstants.speakerColors;
    return colors[(speaker - 1).abs() % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: Text(
        'SPEAKER $speaker',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: colorFor(speaker),
        ),
      ),
    );
  }
}
