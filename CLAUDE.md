# Silsigan — Real-Time Speech Translation App

## Project Overview

Real-time speech translation app built with Flutter. User speaks in any language (auto-detected), sees live transcript, and gets streaming translations powered by Soniox (ASR + translation). Supports multiple target languages: Vietnamese, English, Turkish, Korean.

**Spec file:** `korean_vietnamese_live_translation_spec.md`

---

## Tech Stack

- **Framework:** Flutter (Dart) — iOS 16+ / Android 14+ (API 24+)
- **ASR + Translation:** Soniox (`stt-rt-v4`) via WebSocket — handles both transcription and one-way translation
- **Audio:** `flutter_sound` — PCM16 (pcm_s16le), 24kHz, mono
- **State:** Riverpod
- **Storage:** sqflite (local SQLite, DB version 2 with audio_path column)
- **CI/CD:** Codemagic — builds iOS (TestFlight) and Android (APK)

---

## App IDs & Identifiers

- **Android:** `com.silsigan.app` (namespace + applicationId in build.gradle, MainActivity in `com/silsigan/app/`)
- **iOS:** `com.silsigan.app` (bundle identifier in project.pbxproj)
- **iOS Tests:** `com.silsigan.app.RunnerTests`
- **App Name:** `Silsigan` (capitalized)

---

## API Keys

Stored in `.env.json` (JSON format, gitignored). Loaded via `--dart-define`:

```bash
flutter run --dart-define=SONIOX_API_KEY=...
flutter build apk --dart-define=SONIOX_API_KEY=...
```

Access in Dart: `String.fromEnvironment('SONIOX_API_KEY')`

Only `SONIOX_API_KEY` is needed — Claude/Anthropic API is no longer used.

---

## File Structure

```
lib/
├── main.dart
├── app.dart
├── models/
│   └── transcript_session.dart        # TranscriptSession with audioPath field
├── providers/
│   ├── recording_provider.dart        # RecordingState enum (idle/recording/processing/postRecording)
│   ├── transcript_provider.dart       # koreanDraft + koreanHistory
│   ├── translation_provider.dart      # vietnameseDraft + vietnameseHistory
│   ├── target_language_provider.dart   # TargetLanguage enum (Vietnamese/English/Turkish/Korean)
│   └── session_history_provider.dart  # FutureProvider loading from DB
├── services/
│   ├── soniox_realtime_service.dart   # WebSocket transcription + translation
│   ├── audio_service.dart             # flutter_sound capture + WAV file saving
│   └── database_service.dart          # SQLite singleton — CRUD + audio file cleanup
├── ui/
│   ├── screens/
│   │   └── main_screen.dart           # Live transcription screen (only screen)
│   └── widgets/
│       ├── transcript_panel.dart      # Scrollable text panel with copy button
│       ├── record_button.dart         # Animated mic/stop button with haptics
│       ├── save_discard_row.dart      # Side buttons (history/trash/check)
│       ├── session_card.dart          # History list item card
│       ├── history_sheet.dart         # Bottom sheet with list + detail views
│       └── status_bar.dart            # Pulsing recording/processing indicator
└── utils/
    ├── audio_utils.dart
    └── constants.dart                 # API URLs, audio config, UI design tokens
```

---

## Architecture Notes

### Navigation
- **Single screen app** — `MainScreen` is the only route
- **History:** modal bottom sheet (`HistorySheet`) slides up from bottom
- **Session detail:** shown inline within the same bottom sheet (no separate page)
- **Save flow:** save → opens bottom sheet pre-selected to the saved session

### 3-State Bottom Button Flow
1. **Idle:** History button, Mic button, Check button (unhighlighted)
2. **Recording:** Only Stop button visible (history + check hidden)
3. **PostRecording:** Trash button (red), Mic button, Check button (highlighted)

### Audio Recording
- PCM chunks accumulated in `_fullRecording` buffer during recording
- On save: builds WAV file (44-byte header + PCM data), saves to app documents
- Audio path stored in `sessions` table (`audio_path TEXT`, added in DB v2)
- On delete: audio file is also deleted from disk

### Soniox Translation
- Translation handled by Soniox via `translation` config: `{"type": "one_way", "target_language": "vi"}`
- When target is Korean (same as source), transcription is copied directly to translation panel
- Callbacks: `onTranscriptionDraft/Completed` + `onTranslationDraft/Completed`
- Tokens have `translation_status` field: `"source"` for transcription, `"translation"` for translated text

### New Line Logic
- `endpointDelayMs = 2000` (Soniox endpoint detection)
- Completed utterances append to the last history line (not new line)
- Timer-based new line: only after 4000ms pause (`newLinePauseMs`)

---

## Key Design Decisions

- **Soniox handles both ASR and translation** — no Claude API dependency
- **API keys via `--dart-define`** — no .env file in bundle
- **SQLite (sqflite)** — local-only storage, no cloud sync, singleton pattern, DB v2
- **Riverpod StateProviders** — reactive streams drive UI updates from WebSocket events
- **PCM16 at 24kHz** — compatible with Soniox (`pcm_s16le`)
- **Bottom sheet for history** — no separate pages, everything in modal sheets

---

## UI Design

- Light theme: bg `#EAEAEA`, panels `#FCFCFC`, text `#111111`/`#333333`
- No AppBar on main screen — title "Silsigan" in gray header area
- Panels use uppercase labels: TRANSCRIPTION / TRANSLATION
- Copy-to-clipboard buttons on panels (visible when text exists)
- Text is selectable via `SelectionArea`
- Button press feedback: scale animation + haptics
- Pulsing status dot when recording
- Animated ellipsis on translation draft
- Custom app icon from `silsigan_icon.png`

---

## What NOT to Build (v1)

No auth, no cloud sync, no export, no transcript editing, no speaker diarization, no offline mode, no settings screen, no TTS.

---

## Build & Run

```bash
# Debug on device
flutter run --dart-define=SONIOX_API_KEY=...

# Build release APK
flutter build apk --dart-define=SONIOX_API_KEY=...

# iOS builds via Codemagic (SONIOX_API_KEY set as env var)
```

### Version Bumping
- Version format: `1.0.0+N` in `pubspec.yaml`
- Bump build number (`+N`) for each App Store Connect / TestFlight upload

---

## Build Notes

- AGP 8.7.0, Gradle 8.9, Kotlin 1.9.24 — required for SDK 35
- compileSdk = 35, Java 17, minSdk = 24 (required by flutter_sound)
- iOS deployment target: 16.0
- iOS Podfile includes `-lc++` linker flag (required by native dependencies)
- iOS project.pbxproj has `OTHER_LDFLAGS = -lc++` on Runner target
- `flutter_launcher_icons` with `remove_alpha_ios: true` for App Store compliance

---

## Coding Conventions

- Dart formatting: `dart format .` before commits
- Use `const` constructors where possible
- Riverpod: prefer `StateProvider` for simple state, `FutureProvider` for async DB queries
- Services: expose clean start/stop/dispose interfaces
- Error handling: fail gracefully, never crash — show user-friendly messages
- All UI references should follow the Figma design: https://www.figma.com/design/J5lQW4PqaxOhBiR2vCqrqc/App-MCP?node-id=116-3&m=dev
