# macOS desktop build

Requires macOS 13 Ventura or later (ScreenCaptureKit system-audio capture), Xcode, and Flutter.

From the repo root:

```
flutter build macos --release --dart-define-from-file=.env.json
```

The unsigned `.app` lands at:

```
build/macos/Build/Products/Release/Silsigan.app
```

Unsigned is OK (the Windows installer is unsigned too). Drag the `.app` to `/Applications` or run it in place.

## First run — permissions

Speaker / Both capture uses ScreenCaptureKit, which macOS gates behind Screen Recording (and, on newer macOS, Screen & System Audio Recording). The microphone still uses the usual mic permission.

On first Speaker/Both start, grant:

- **System Settings → Privacy & Security → Microphone**
- **System Settings → Privacy & Security → Screen Recording** (or **Screen & System Audio Recording**)

If capture is silent after granting, quit and reopen Silsigan — TCC sometimes applies only on the next launch.

`.env.json` is local and must not be committed.