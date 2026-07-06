import 'package:flutter/material.dart';

class AppConstants {
  // Server
  static const serverBaseUrl = 'https://silsigan.onrender.com';

  // Soniox (proxied through our server)
  static const sonioxProxyUrl = 'wss://proxy.silsigan.xyz/ws/soniox';
  static const sonioxLimitedProxyUrl =
      'wss://proxy.silsigan.xyz/ws/soniox-limited';
  static const sonioxModel = 'stt-rt-v5';
  static const transcriptionLanguage = 'ko';

  // Audio
  static const sampleRate = 24000;
  static const numChannels = 1;
  static const chunkIntervalMs = 100;
  static const audioFormat = 'pcm_s16le';
  static const endpointDelayMs = 2000;
  // Soniox v5 endpoint tuning (v5-only; ignored by older models). Kept at
  // neutral defaults so they live in one place for post-launch tuning.
  //   endpointSensitivity:            -1.0..1.0  (higher = endpoints fire sooner)
  //   endpointLatencyAdjustmentLevel:  0..3      (higher = wait for more accurate
  //                                               final tokens at the endpoint)
  static const endpointSensitivity = 0.0;
  static const endpointLatencyAdjustmentLevel = 0;
  static const newLinePauseMs = 2000;
  static const maxParagraphSentences = 4;

  // Line-by-line endpoint tuning. In line-by-line mode each Soniox endpoint
  // becomes its own aligned line, so mid-sentence endpoints produce fragments
  // that Soniox translates without the sentence's subject (Korean is
  // subject-first + pro-drop). Delaying the endpoint until a fuller/sentence
  // boundary lets Soniox translate a complete clause, at the cost of a bit
  // more latency before each line appears. Split mode masks the same
  // fragmentation by concatenating fragments into paragraphs, so it keeps the
  // snappier neutral defaults above.
  static const lineByLineEndpointDelayMs = 5000;
  static const lineByLineEndpointSensitivity = -0.4;
  static const lineByLineEndpointLatencyAdjustmentLevel = 2;

  // UI — Figma design tokens
  static const Color bgColor = Color(0xFFEAEAEA);
  static const Color panelColor = Color(0xFFFCFCFC);
  static const Color dividerColor = Color(0xFFF5F5F5);
  static const Color textPrimary = Color(0xFF111111);
  static const Color textSecondary = Color(0xFF333333);
  static const Color micButtonColor = Color(0xFF111111);
  static const Color historyButtonColor = Color(0xFF333333);
  static const Color saveButtonColor = Color(0xFFBEBEBE);
  static const Color saveButtonActiveColor = Color(0xFF333333);

  static const double titleFontSize = 24.0;
  static const double labelFontSize = 14.0;
  static const double contentFontSize = 15.0;
  // Quick Mode uses larger text for at-a-glance reading.
  static const double quickFontSize = 30.0;
  static const double langFontSize = 17.0;
  static const double panelBorderRadius = 10.0;
  static const double panelPaddingH = 26.0;
  static const double micButtonSize = 84.0;
  static const double sideButtonSize = 50.0;
  static const double sideIconSize = 27.0;
  static const double micIconSize = 36.0;
  static const double langBoxHeight = 37.0;
  static const double langBoxWidth = 133.0;
  static const double langBoxRadius = 5.0;

  static const historyOpacity = 0.6;
  static const previewMaxLength = 80;

  // Text-selection highlight. Without an explicit theme, Material 3 derives
  // the selection color from the grey seed (primary @ 40%), which paints
  // selected transcript text with a gray film that reads as the text itself
  // changing color.
  static const Color selectionHighlightColor = Color(0x471A73E8);
  static const Color selectionHandleColor = Color(0xFF1A73E8);

  // Speaker diarization label colors — one per detected speaker, cycled.
  // Muted-but-distinct hues that stay readable on the light panels
  // (#FCFCFC / #F0F0F0). Soniox supports up to 15 speakers per session;
  // beyond the palette the colors repeat.
  static const List<Color> speakerColors = [
    Color(0xFF1A73E8), // blue
    Color(0xFFC5221F), // red
    Color(0xFF188038), // green
    Color(0xFF9334E6), // purple
    Color(0xFFE8710A), // orange
    Color(0xFF12805C), // teal
    Color(0xFFB80672), // magenta
    Color(0xFF5F6368), // gray
  ];
}
