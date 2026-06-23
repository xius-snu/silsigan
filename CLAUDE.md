# Silsigan — Real-Time Speech Translation App

## Project Overview

Real-time speech translation app built with Flutter. User speaks in any language (auto-detected), sees live transcript, and gets streaming translations powered by Soniox (ASR + translation). Five display modes (line-by-line, split, conversation, transcription, quick) and eight target languages.

**Spec file:** `korean_vietnamese_live_translation_spec.md`

---

## Tech Stack

- **Framework:** Flutter (Dart) — iOS 16+ / Android 14+ (API 24+)
- **ASR + Translation:** Soniox (`stt-rt-v5`) via WebSocket — proxied through our own server
- **Audio:** `flutter_sound` — PCM16 (pcm_s16le), 24kHz, mono
- **TTS:** `flutter_tts` — native OS voices (iOS AVSpeechSynthesizer, Android system TTS)
- **State:** Riverpod
- **Storage:** sqflite (local SQLite, **DB version 5**)
- **Purchases:** RevenueCat (`purchases_flutter`) — iOS only
- **Background:** `flutter_foreground_task` — Android only, keeps recording alive
- **CI/CD:** Codemagic — builds iOS (TestFlight) and Android (APK)

---

## App IDs & Identifiers

- **Android:** `com.silsigan.app` (namespace + applicationId in build.gradle, MainActivity in `com/silsigan/app/`)
- **iOS:** `com.silsigan.app` (bundle identifier in project.pbxproj)
- **iOS Tests:** `com.silsigan.app.RunnerTests`
- **App Name:** `Silsigan` (capitalized)
- **Current version:** see `pubspec.yaml` (`1.0.6+29` at last update)

---

## Servers

Two separate Node services back the app:

- **Render API** (`silsigan.onrender.com`) — `server/index.js` (Fastify + Postgres). Friend system, auth, usage tracking, RevenueCat webhook, friend-to-friend session relay (`/ws/session`). **Auto-deploys on push to master.**
- **Hetzner WS proxy** (`proxy.silsigan.xyz`) — `server/proxy-standalone.js`. Forwards client audio to `wss://stt-rt.soniox.com`, attaches the Soniox key, meters audio bytes, and force-closes WS with code **4005** when the user crosses their usage limit. **NOT auto-deployed** — manual deploy required (see [Hetzner proxy deploy](memory/reference_hetzner_proxy_deploy.md)).

Two Soniox WS endpoints on the proxy:
- `/ws/soniox` — full-quality key pool
- `/ws/soniox-limited` — limited key pool (default for end users)
- `?private=1` query param selects the dedicated private key (gated by `SONIOX_PRIVATE` build flag or server-side `isPrivate` user flag)

---

## API Keys

**The client no longer holds the Soniox key.** The proxy attaches it server-side. The only build-time flag is:

```bash
flutter run --dart-define=SONIOX_PRIVATE=true   # routes through full-quality key
flutter build apk                                # APKs build with no dart-defines
```

Render env vars: `SONIOX_API_KEYS`, `LIMITED_SONIOX_API_KEYS`, `SONIOX_PRIVATE_KEY`, `DATABASE_URL`, `PUBLIC_ACCESS_DISABLED`, RevenueCat webhook secret.

---

## File Structure

```
lib/
├── main.dart                              # Initializes BackgroundService + UserService
├── app.dart
├── models/
│   ├── transcript_session.dart            # +title, +timestampsJson, +audioPath
│   └── word_timestamp.dart                # Per-word ms offsets for audio scrubbing
├── providers/
│   ├── recording_provider.dart            # idle/recording/processing/postRecording
│   ├── display_mode_provider.dart         # lineByLine/split/conversation/transcription/quick
│   ├── target_language_provider.dart      # 8 languages (see below)
│   ├── detected_language_provider.dart    # Soniox-detected source language
│   ├── transcript_provider.dart           # koreanDraft + koreanHistory (legacy naming)
│   ├── translation_provider.dart          # vietnameseDraft + vietnameseHistory (legacy naming)
│   ├── conversation_provider.dart         # Conversation mode: myLanguage/theirLanguage/messages
│   ├── quick_provider.dart                # Quick mode: quickTranscript + quickTranslation (strings)
│   ├── tts_provider.dart                  # ttsEnabled, ttsRate (0.5–1.5×)
│   └── session_history_provider.dart      # FutureProvider over SQLite
├── services/
│   ├── soniox_realtime_service.dart       # WS to proxy; rotation timer, reconnect, 4005 handling
│   ├── audio_service.dart                 # flutter_sound capture + WAV file saving
│   ├── tts_service.dart                   # flutter_tts queue, per-language locale map
│   ├── database_service.dart              # SQLite singleton — sessions + autosave_draft
│   ├── user_service.dart                  # Auth, friend code, hardware ID, usage, invites
│   ├── sync_service.dart                  # Upload saved sessions to Render
│   ├── session_relay_service.dart         # WS to /ws/session for live friend sessions
│   ├── purchase_service.dart              # RevenueCat init/purchase/pending retry
│   ├── update_service.dart                # Force-update check
│   └── background_service.dart            # Android foreground service (flutter_foreground_task)
├── ui/
│   ├── screens/
│   │   ├── main_screen.dart               # Primary screen — all display modes
│   │   └── live_session_screen.dart       # Friend-to-friend live translation room
│   └── widgets/
│       ├── transcript_panel.dart          # Split-mode scrollable panel with copy button
│       ├── line_by_line_panel.dart        # Aligned per-utterance pairs with audio scrubbing
│       ├── conversation_panel.dart        # Chat-bubble UI with two-sided mic
│       ├── quick_panel.dart               # Quick mode: big-text top/bottom + press-and-hold mic
│       ├── record_button.dart             # Animated mic/stop with haptics
│       ├── save_discard_row.dart          # idle/postRecording side buttons
│       ├── history_sheet.dart             # Bottom sheet: list + inline detail + audio player
│       ├── session_card.dart              # History list item
│       ├── status_bar.dart                # Pulsing recording dot + remaining time
│       ├── friend_dialog.dart             # Friend-code input + outgoing invite
│       ├── session_invite_banner.dart     # Incoming invite UI on main screen
│       └── tts_control_button.dart        # TTS toggle + rate slider
└── utils/
    ├── audio_utils.dart
    └── constants.dart                     # serverBaseUrl, proxy URLs, design tokens

server/
├── index.js                               # Render API (Fastify + Postgres)
├── proxy-standalone.js                    # Hetzner Soniox proxy
├── package.json
└── .env.example
```

---

## Display Modes

`DisplayMode` enum (saved via SharedPreferences):

1. **`lineByLine`** (default) — each Soniox endpoint = one segment; transcription + translation lines aligned 1:1; supports audio scrubbing via word timestamps.
2. **`split`** — two scrollable panels (transcript/translation); paragraph breaks on 2s pause or 4 sentences; late translations re-attach to their paragraph.
3. **`conversation`** — chat bubbles, two language slots (`myLanguageProvider` / `theirLanguageProvider`); tap either side to record as that speaker.
4. **`transcription`** — transcript only, no translation (skips Soniox `translation` config).
5. **`quick`** — press-and-hold "walkie-talkie" translator (`QuickPanel`, self-contained). Big text, transcription top / translation bottom, no save/history. Hold the mic to record; the first transcribed word clears the previous result; release stops audio input, lets the trailing translation settle (~700ms), then speaks the full translation via TTS (always on, independent of the global toggle). State lives in `quick_provider.dart` (`quickTranscript` / `quickTranslation` — single growing strings, not history lists).

---

## Target Languages

Eight languages in `TargetLanguage` enum: **Vietnamese, English, Turkish, Chinese, Korean, Japanese, Thai, Malay**. Each has a `displayName` and ISO `code`. TTS support matches the locale map in `tts_service.dart`.

---

## Architecture Notes

### Navigation
- `MainScreen` is the primary route; live-friend sessions push `LiveSessionScreen`.
- History: modal bottom sheet (`HistorySheet`) — list + inline detail + audio player.
- Save flow: save → open history sheet with the saved session pre-selected.
- Purchase, friend dialog, and TTS settings are all modal sheets/dialogs.

### 3-State Bottom Button Flow
1. **Idle:** History, Mic, Check (unhighlighted)
2. **Recording:** Stop only (history + check hidden)
3. **PostRecording:** Trash (red), Mic, Check (highlighted)

### Audio Recording
- PCM chunks accumulated in `_fullRecording` during recording.
- On save: 44-byte WAV header + PCM → file in app documents → path in `sessions.audio_path`.
- On delete: audio file is removed from disk.
- **Word timestamps** captured per utterance and saved per-line as JSON in `sessions.timestamps_json` for line-by-line audio scrubbing.

### Soniox Translation & Reconnect
- Translation via Soniox `translation` config: `{"type": "one_way", "target_language": "<code>"}`.
- When target == source (e.g. Korean→Korean), transcription is copied into the translation panel.
- **Rotation timer:** WS is rotated every 10 minutes to prevent translation model degradation in long sessions; `contextText` (last 10 history lines) is replayed to keep continuity.
- **Reconnect:** up to 50 attempts; audio buffered (capped at 30s) during reconnection.
- **Late translation flush:** translations arriving after the source endpoint are debounced 800ms so they don't merge with the next utterance.
- **Server-authoritative usage limit:** when the proxy closes WS with **code 4005**, `onUsageLimitReached` fires → recording stops + paywall dialog. The client does NOT run its own timer; see [usage timer behavior](memory/feedback_apk_build.md).

### New Line / Paragraph Logic (split mode)
- `endpointDelayMs = 2000` (Soniox endpoint detection)
- `newLinePauseMs = 2000` — timer-based paragraph break after this pause.
- `maxParagraphSentences = 4` — force paragraph break after this many sentences (1s deferred so late translations still land on the right line).
- Completed utterances append to the last history line; translations re-attach across paragraph boundaries.

### Autosave
- Periodic `Timer.periodic(15s)` while recording; also fires on background/pause and on stop.
- Stored in `autosave_draft` table (single row, `id = 1`).
- Restored on app launch if `RecordingState == idle` and a draft exists.

### Friend & Live Session System
- `UserService` registers the device on first launch (hardware ID for stable identity), generates a 6-char friend code, fetches an auth token.
- Friend invites: `FriendDialog` → POST to Render → poll for accept/reject → push `LiveSessionScreen`.
- `SessionRelayService` opens a WS to `/ws/session` so both participants see each other's drafts + completed translations in real time.
- Activity reporting: `UserService.reportActivity('event_name', metadata)` for analytics (app_open, recording_start/stop, session_save, …).

### Background Recording
- Android: `flutter_foreground_task` with a low-importance notification keeps the process alive during recording.
- iOS: no foreground service — on resume from paused, both WS and audio capture are restarted because iOS kills audio + network in background.
- App lifecycle: `paused` triggers autosave + sets `_wasPaused`; `resumed` restarts audio only if `_wasPaused` (filters out transient `inactive` from Control Center, etc.).

### Purchases
- RevenueCat package identifiers: `hours_1`, `hours_5`, `hours_10`, `hours_30`, `hours_50` (60, 300, 600, 1800, 3000 minutes respectively).
- iOS only — Android shows mock UI with "not available" snackbar.
- Successful purchase → POST to Render to credit minutes → refresh `_usedSeconds` / `_limitMinutes`.
- Pending purchases (Apple credited but server failed) are persisted and retried on next launch.
- Redeem code section lets users enter a server-issued code.

---

## Database Schema (DB v5)

`sessions`:
- `id`, `created_at`, `korean_full`, `vietnamese_full`, `korean_preview`, `vietnamese_preview`
- `audio_path` (v2), `timestamps_json` (v3), `title` (v5)

`autosave_draft` (v4, single-row):
- `id` (= 1), `korean_history`, `vietnamese_history`, `word_timestamps`, `target_language`, `created_at`, `updated_at`

Migrations are additive — see `_initDatabase` in `database_service.dart`.

---

## Key Design Decisions

- **Server proxy is mandatory** — the client never talks to Soniox directly. The proxy attaches keys and meters usage.
- **Server-authoritative usage** — proxy bills bytes, closes WS with 4005 when exceeded. Client trusts that signal and does not run a parallel timer.
- **`flutter_tts` (native OS) over cloud TTS** — free, offline once voices are installed, no API key.
- **Hardware ID identity** — survives app data clear (Android) + uninstall (iOS) so usage limits can't be reset by reinstalling.
- **SQLite is local-only**; uploads happen via `SyncService` (fire-and-forget) and are best-effort.
- **Riverpod `StateProvider`** for simple state, `FutureProvider` for async DB queries. WebSocket callbacks drive provider updates.
- **PCM16 at 24kHz** — Soniox-compatible (`pcm_s16le`).
- **No separate routes** — single screen + modal bottom sheets. Friend live sessions are the one exception.

---

## UI Design

- Light theme only: bg `#EAEAEA`, panels `#FCFCFC`, text `#111111`/`#333333`.
- No AppBar on main screen — title "Silsigan" in gray header area.
- Panels use uppercase labels: TRANSCRIPTION / TRANSLATION.
- Copy-to-clipboard buttons (visible when text exists), `SelectionArea` for selection.
- Button press feedback: scale animation + haptics, 120ms transitions.
- Pulsing status dot when recording; animated ellipsis on translation draft.
- Custom app icon from `silsigan_icon.png`.
- Figma design: https://www.figma.com/design/J5lQW4PqaxOhBiR2vCqrqc/App-MCP?node-id=116-3&m=dev

---

## What NOT to Build (v1)

No auth UI (it's invisible/automatic via device ID), no cloud sync UI (sync is automatic + best-effort), no transcript editing, no speaker diarization beyond conversation mode, no offline ASR, no full settings screen (settings live inline as modals).

---

## Build & Run

```bash
# Debug on device
flutter run

# Debug with private Soniox key
flutter run --dart-define=SONIOX_PRIVATE=true

# Build release APK (no API keys needed — proxy handles auth)
flutter build apk

# iOS builds via Codemagic
```

### Version Bumping
- Format: `1.0.X+N` in `pubspec.yaml`.
- Bump `+N` for each App Store Connect / TestFlight upload.

---

## Build Notes

- AGP 8.7.0, Gradle 8.9, Kotlin 1.9.24 — required for SDK 35
- compileSdk = 35, Java 17, minSdk = 24 (required by flutter_sound)
- iOS deployment target: 16.0
- iOS Podfile includes `-lc++` linker flag (required by native dependencies)
- iOS project.pbxproj has `OTHER_LDFLAGS = -lc++` on Runner target
- `flutter_launcher_icons` with `remove_alpha_ios: true` for App Store compliance
- Android MainActivity: `com/silsigan/app/MainActivity.kt` (must match app ID)
- Hardware ID exposed via `MethodChannel('com.silsigan.app/hardware_id')` — native code on both platforms

---

## Coding Conventions

- `dart format .` before commits.
- Use `const` constructors where possible.
- Riverpod: prefer `StateProvider` for simple state, `FutureProvider` for async DB queries.
- Services expose clean start/stop/dispose interfaces and are typically singletons.
- Fail gracefully — never crash. Show user-friendly messages, throttle error snackbars (10s) on reconnect storms.
- All UI references should follow the Figma design linked above.
