import 'package:flutter/material.dart';
import '../../providers/target_language_provider.dart';
import '../../providers/detected_language_provider.dart';
import '../../utils/constants.dart';

/// Left-side source-language selector. "Any" (null) means auto-detect; the user
/// can also pin a specific source language (e.g. English → Vietnamese). While
/// recording with "Any" selected, the box shows the detected language as live
/// feedback (the popup itself is disabled mid-session).
class SourceLanguageSelector extends StatelessWidget {
  final TargetLanguage? source;
  final String? detectedLanguage;
  final bool isRecording;
  final bool enabled;
  final ValueChanged<TargetLanguage?> onChanged;
  final Color? boxColor;
  final Color? textColor;

  const SourceLanguageSelector({
    super.key,
    required this.source,
    required this.detectedLanguage,
    required this.isRecording,
    required this.enabled,
    required this.onChanged,
    this.boxColor,
    this.textColor,
  });

  // Sentinel for the "Any" item — PopupMenuButton treats a null selected value
  // as a cancellation, so "Any" can't use null as its menu value.
  static const _anyValue = '__any__';

  @override
  Widget build(BuildContext context) {
    final String label;
    if (source != null) {
      label = source!.displayName;
    } else if (isRecording && detectedLanguage != null) {
      label = languageDisplayName(detectedLanguage!);
    } else {
      label = 'Any';
    }

    return PopupMenuButton<String>(
      enabled: enabled,
      onSelected: (code) =>
          onChanged(code == _anyValue ? null : TargetLanguage.fromCode(code)),
      offset: const Offset(0, -160),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: _anyValue,
          child: Row(
            children: [
              const Expanded(child: Text('Any')),
              if (source == null) const Icon(Icons.check, size: 18),
            ],
          ),
        ),
        ...TargetLanguage.values.map(
          (lang) => PopupMenuItem<String>(
            value: lang.code,
            child: Row(
              children: [
                Expanded(child: Text(lang.displayName)),
                if (source == lang) const Icon(Icons.check, size: 18),
              ],
            ),
          ),
        ),
      ],
      child: Container(
        width: AppConstants.langBoxWidth,
        height: AppConstants.langBoxHeight,
        decoration: BoxDecoration(
          color: boxColor ?? AppConstants.panelColor,
          borderRadius: BorderRadius.circular(AppConstants.langBoxRadius),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppConstants.langFontSize,
            color: textColor ?? AppConstants.textPrimary,
          ),
        ),
      ),
    );
  }
}
