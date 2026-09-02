import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Desktop shells (Windows / Linux / macOS). False on iOS, Android, and web
/// so those builds never compile in a desktop-only control.
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// System-audio (speaker) loopback is implemented on Windows (WASAPI),
/// macOS (ScreenCaptureKit), and Linux (Pulse/PipeWire monitor sources).
bool get desktopSpeakerCaptureSupported {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}
