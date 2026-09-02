import 'package:flutter/material.dart';

class AppConstants {
  // Server
  static const serverBaseUrl = 'https://silsigan.onrender.com';

  // Store / legal
  static const privacyPolicyUrl = 'https://xius-snu.github.io/silsigan/privacy';
  static const termsOfUseUrl = 'https://xius-snu.github.io/silsigan/terms';
  static const appleEulaUrl =
      'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/';
  static const appStoreUrl =
      'https://apps.apple.com/us/app/silsigan/id6760031656';
  static const playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.silsigan.app';

  // ── Account sync (optional Google / Apple login) ──
  // OAuth client IDs are public identifiers, not secrets — they ship in the
  // binary either way (iOS needs the reversed ID as a URL scheme in
  // Info.plist). Leaving a value empty hides that sign-in button rather than
  // failing at tap time. Register these in Google Cloud Console → Credentials
  // and mirror them into the server's GOOGLE_CLIENT_IDS.
  static const googleIosClientId = '287776800654-rebo3m3pe7fp1ape20ktqk5mc7e2pn50.apps.googleusercontent.com';
  // The Web client ID. Android's Credential Manager flow needs it as the
  // "server" client so the ID token's audience is stable across platforms.
  static const googleServerClientId = '287776800654-eqfu7k983n904heci4qdm1ffj9ekd5vi.apps.googleusercontent.com';

  /// Free allowance a device starts with, mirrored from the server's
  /// FREE_BASE_MINUTES. Only used for copy in the account sheet — the server
  /// stays authoritative for the real balance.
  static const freeBaseMinutes = 30;

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
  // Per soniox.com/docs/stt/rt/endpoint-detection:
  //   endpointSensitivity:            -1.0..1.0  (higher = endpoints fire sooner)
  //   endpointLatencyAdjustmentLevel:  0..3      (higher = endpoints returned
  //                                               SOONER; combining a level > 0
  //                                               with negative sensitivity is
  //                                               explicitly not recommended —
  //                                               they work against each other)
  //   max_endpoint_delay_ms:           500..3000 (values outside this range are
  //                                               undocumented behavior)
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
  //
  // Retuned 2026-07-16: the original values (5000 / -0.4 / 2) violated the
  // documented 500–3000 delay range and paired negative sensitivity with a
  // latency adjustment level that pulls endpoints SOONER — the two knobs were
  // fighting each other. Now: modest negative sensitivity alone defers
  // premature mid-clause endpoints, the delay ceiling sits at the documented
  // maximum, and the adjustment level stays neutral as the docs recommend.
  static const lineByLineEndpointDelayMs = 3000;
  static const lineByLineEndpointSensitivity = -0.2;
  static const lineByLineEndpointLatencyAdjustmentLevel = 0;

  // ── Theme ──
  // Whether the dark palette is active. Set by SilsiganApp from
  // darkModeProvider before the tree builds (toggle-driven only — never the
  // OS setting); every color getter below resolves against it. Widgets don't
  // listen to this flag — the screens watch the provider and rebuild, and
  // their subtrees re-read the getters.
  static bool isDark = false;

  // UI — Figma design tokens (light) with a derived dark palette. These are
  // getters, not consts, so the whole app follows the toggle without
  // threading a theme object through every widget.
  static Color get bgColor =>
      isDark ? const Color(0xFF161618) : const Color(0xFFEAEAEA);
  static Color get panelColor =>
      isDark ? const Color(0xFF232326) : const Color(0xFFFCFCFC);
  static Color get dividerColor =>
      isDark ? const Color(0xFF2C2C2F) : const Color(0xFFF5F5F5);
  static Color get textPrimary =>
      isDark ? const Color(0xFFF2F2F3) : const Color(0xFF111111);
  static Color get textSecondary =>
      isDark ? const Color(0xFFC6C6CB) : const Color(0xFF333333);

  /// Hint-tier text (grey[500]/grey[600] in the light design).
  static Color get textMuted =>
      isDark ? const Color(0xFF8E8E93) : const Color(0xFF9E9E9E);

  /// Faint text — legal links, separators (grey[300]/grey[400] in light).
  static Color get textFaint =>
      isDark ? const Color(0xFF6E6E73) : const Color(0xFFBDBDBD);

  // The mic surfaces invert in dark mode (light circle, dark glyph) so the
  // primary action never disappears into the background.
  static Color get micButtonColor =>
      isDark ? const Color(0xFFF2F2F3) : const Color(0xFF111111);

  /// Icon/spinner drawn ON mic-colored surfaces (mic button, active swap
  /// circle) — pairs with [micButtonColor]'s inversion.
  static Color get micIconColor =>
      isDark ? const Color(0xFF111111) : Colors.white;
  static Color get historyButtonColor =>
      isDark ? const Color(0xFF48484C) : const Color(0xFF333333);
  static Color get saveButtonColor =>
      isDark ? const Color(0xFF3A3A3E) : const Color(0xFFBEBEBE);
  static Color get saveButtonActiveColor =>
      isDark ? const Color(0xFFE2E2E6) : const Color(0xFF333333);

  /// Check glyph on the highlighted save button — pairs with the
  /// [saveButtonActiveColor] inversion above.
  static Color get saveButtonActiveIconColor =>
      isDark ? const Color(0xFF111111) : Colors.white;

  /// Modal bottom sheets (purchase sheet) and blocking overlay cards.
  static Color get sheetColor =>
      isDark ? const Color(0xFF1F1F22) : Colors.white;

  // Purchase-sheet package cards.
  static Color get cardColor => isDark ? const Color(0xFF29292D) : Colors.white;
  static Color get cardBorderColor =>
      isDark ? const Color(0xFF3A3A3E) : const Color(0xFFE0E0E0);
  static Color get cardHighlightColor =>
      isDark ? const Color(0xFF2E2E38) : const Color(0xFFF8F8FF);
  static Color get cardHighlightBorderColor =>
      isDark ? const Color(0xFF8E8E98) : const Color(0xFF4A4A4A);

  // Line-by-line paired blocks.
  static Color get lineTranscriptionBlockColor =>
      isDark ? const Color(0xFF2C2C30) : const Color(0xFFF0F0F0);
  static Color get lineTranslationBlockColor =>
      isDark ? const Color(0xFF253140) : const Color(0xFFE8F0FE);

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
  // Muted-but-distinct hues per theme (the light set stays readable on
  // #FCFCFC/#F0F0F0 panels; the dark set on #232326/#2C2C30). Soniox supports
  // up to 15 speakers per session; beyond the palette the colors repeat.
  static List<Color> get speakerColors =>
      isDark ? _speakerColorsDark : _speakerColorsLight;

  static const List<Color> _speakerColorsLight = [
    Color(0xFF1A73E8), // blue
    Color(0xFFC5221F), // red
    Color(0xFF188038), // green
    Color(0xFF9334E6), // purple
    Color(0xFFE8710A), // orange
    Color(0xFF12805C), // teal
    Color(0xFFB80672), // magenta
    Color(0xFF5F6368), // gray
  ];

  static const List<Color> _speakerColorsDark = [
    Color(0xFF8AB4F8), // blue
    Color(0xFFF28B82), // red
    Color(0xFF81C995), // green
    Color(0xFFC58AF9), // purple
    Color(0xFFFDA663), // orange
    Color(0xFF6FCFB2), // teal
    Color(0xFFFF8BCB), // magenta
    Color(0xFF9AA0A6), // gray
  ];
}
