import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Desktop shells (Windows / Linux / macOS). False on iOS, Android, and web.
/// Used for desktop-only chrome (browser OAuth, etc.).
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// Header Mic / Speaker / Both control. True on Windows, Linux, macOS, and
/// Android. Hidden on iPhone / iPad (ReplayKit cannot capture YouTube /
/// Safari / Music audio) and on web.
bool get audioSourceSelectorSupported {
  if (kIsWeb) return false;
  return Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isAndroid;
}

/// Android — used for first-run MediaProjection capture-sheet copy.
bool get isMobileSpeakerCapture {
  if (kIsWeb) return false;
  return Platform.isAndroid;
}

bool get isIOSPlatform {
  if (kIsWeb) return false;
  return Platform.isIOS;
}

bool get isAndroidPlatform {
  if (kIsWeb) return false;
  return Platform.isAndroid;
}

/// System-audio (speaker) loopback:
/// Windows WASAPI, macOS ScreenCaptureKit, Linux Pulse/PipeWire monitors,
/// Android 10+ MediaProjection AudioPlaybackCapture.
/// iPhone / iPad ReplayKit cannot capture AVPlayer / YouTube audio, so
/// speaker capture is not offered there.
bool get desktopSpeakerCaptureSupported {
  if (kIsWeb) return false;
  return Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isAndroid;
}
