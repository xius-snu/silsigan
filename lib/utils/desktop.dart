import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Desktop shells (Windows / Linux / macOS). False on iOS, Android, and web.
/// Used for desktop-only chrome (browser OAuth, etc.).
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// Header Mic / Speaker / Both control. True on Windows, Linux, macOS,
/// Android, iPhone and iPad. Hidden on web.
bool get audioSourceSelectorSupported {
  if (kIsWeb) return false;
  return Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isAndroid ||
      Platform.isIOS;
}

/// Android and iPhone / iPad: speaker capture needs a system consent sheet
/// (MediaProjection / ReplayKit Start Broadcast) before it can start.
bool get isMobileSpeakerCapture {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
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
/// Android 10+ MediaProjection AudioPlaybackCapture, iPhone / iPad ReplayKit
/// broadcast (ios/ScreenAudio). On every mobile platform, apps that block
/// screen recording (DRM video, some music apps) stay silent.
bool get desktopSpeakerCaptureSupported {
  if (kIsWeb) return false;
  return Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isAndroid ||
      Platform.isIOS;
}
