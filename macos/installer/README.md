# macOS desktop build

Requires macOS 13 Ventura or later (ScreenCaptureKit system-audio capture), Xcode, and Flutter.

From the repo root, on a Mac, at this `pubspec.yaml` version (`FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`):

```
flutter pub get
flutter build macos --release
```

Do **not** pass `--dart-define-from-file=.env.json` for store builds. The client talks to the proxy; production binaries must not set `SONIOX_PRIVATE`.

The unsigned `.app` lands at:

```
build/macos/Build/Products/Release/Silsigan.app
```

Version / build number come from `pubspec.yaml` (`FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER`). For the Mac App Store, archive and upload from Xcode or Codemagic using automatic signing on bundle `com.silsigan.app` — Sign in with Apple and Push Notifications must stay enabled on that App ID.

## First run — permissions

Speaker / Both capture uses ScreenCaptureKit, which macOS gates behind Screen Recording (and, on newer macOS, Screen & System Audio Recording). The microphone still uses the usual mic permission.

On first Speaker/Both start, grant:

- **System Settings → Privacy & Security → Microphone**
- **System Settings → Privacy & Security → Screen Recording** (or **Screen & System Audio Recording**)

If capture is silent after granting, quit and reopen Silsigan — TCC sometimes applies only on the next launch.
