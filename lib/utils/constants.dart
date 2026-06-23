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
}
