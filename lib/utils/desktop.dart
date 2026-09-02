import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Desktop shells (Windows / Linux / macOS). False on iOS, Android, and web.
/// Used for desktop-only chrome (browser OAuth, etc.), not the audio-source
/// selector — that also ships on iOS and Android.
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// Header Mic / Speaker / Both control. True on desktop, iPhone, iPad, and
/// Android. Hidden on web.
bool get audioSourceSelectorSupported {
  if (kIsWeb) return false;
  return Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isAndroid;
}

/// iPhone / iPad / Android — used for first-run capture-sheet copy.
bool get isMobileSpeakerCapture {
  if (kIsWeb) return false;
  return Platform.isIOS || Platform.isAndroid;
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
/// Android 10+ MediaProjection AudioPlaybackCapture, iOS/iPadOS ReplayKit
/// Broadcast (screen audio).
bool get desktopSpeakerCaptureSupported {
  if (kIsWeb) return false;
  return Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS ||
      Platform.isAndroid;
}
