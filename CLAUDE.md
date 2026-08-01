# Silsigan — Real-Time Speech Translation App

## Project Overview

Real-time speech translation app built with Flutter. User speaks in any language (auto-detected), sees live transcript, and gets streaming translations powered by Soniox (ASR + translation). Five display modes (line-by-line, split, conversation, transcription, quick), twelve target languages, and a light/dark theme toggle.

**Spec file:** `korean_vietnamese_live_translation_spec.md`

---

## Tech Stack

- **Framework:** Flutter (Dart) — iOS 16+ / Android 14+ (API 24+)
- **ASR + Translation:** Soniox (`stt-rt-v5`) via WebSocket — proxied through our own server
- **Audio:** PCM16 (pcm_s16le), 24kHz, mono — captured via `record` on Android/desktop and `flutter_sound` on iOS only. **Do not move Android back to flutter_sound:** its streaming engine polls AudioRecord on the Android platform main thread via a self-reposting runnable whose queue population grows every read — after ~30-60min it saturates the main looper (device heat, hard UI freeze on resume, laggy relaunch that survives swipe-away because the mic FGS keeps the process alive). iOS stays on flutter_sound because its `openRecorder` also configures the playAndRecord audio session TTS depends on.
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

- **Render API** (`silsigan.onrender.com`) — `server/index.js` (Fastify + Postgres). Auth, usage tracking, RevenueCat webhook. (The server still exposes legacy friend/session-relay endpoints, but the client no longer uses them.) **Auto-deploys on push to master.**
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
│   ├── target_language_provider.dart      # 8 languages + sourceLanguageProvider (null = Any)
│   ├── detected_language_provider.dart    # Soniox-detected source language
│   ├── theme_provider.dart                # darkModeProvider (toggle-driven, persisted)
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
│   ├── user_service.dart                  # Auth, customer ID (friend code), hardware ID, usage
│   ├── sync_service.dart                  # Upload saved sessions to Render
│   ├── purchase_service.dart              # RevenueCat init/purchase/pending retry
│   ├── update_service.dart                # Force-update check
│   └── background_service.dart            # Android foreground service (flutter_foreground_task)
├── ui/
│   ├── screens/
│   │   ├── main_screen.dart               # Primary screen — all display modes
│   │   └── consent_screen.dart            # One-time data-sharing consent gate
│   └── widgets/
│       ├── transcript_panel.dart          # Split-mode scrollable panel with copy button
│       ├── line_by_line_panel.dart        # Aligned per-utterance pairs with audio scrubbing
│       ├── conversation_panel.dart        # Chat-bubble UI; two-sided shared toggle mic (two-way)
│       ├── quick_panel.dart               # Quick mode: big-text top/bottom + press-and-hold mic
│       ├── source_language_selector.dart  # Left-side source picker (Any/auto-detect or pinned)
│       ├── record_button.dart             # Animated mic/stop with haptics
│       ├── save_discard_row.dart          # idle/postRecording side buttons
│       ├── history_sheet.dart             # Bottom sheet: list + inline detail + audio player
│       ├── session_card.dart              # History list item
│       ├── status_bar.dart                # Pulsing recording dot + remaining time
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
3. **`conversation`** — chat bubbles, two language slots (`myLanguageProvider` / `theirLanguageProvider`). Uses Soniox **two-way translation** (`{"type":"two_way","language_a","language_b"}`): a **single toggle** (tap either mic) starts one shared listening session and both people speak in turn — no button holding. Each utterance is auto-routed to the correct side by its Soniox-detected source language (original tokens carry `language`; translation tokens carry `source_language`), and each completed translation is spoken aloud in the *listener's* language. TTS **defaults off** (playing audio out loud on a shared two-way mic invites echo); enabling it via the speaker button in the header (`conversationTtsEnabledProvider`) first prompts the user to put on headphones. When on, it's cut when the other side takes the floor. `activeConversationSpeakerProvider` tracks the current detected speaker (drives the live draft bubble); `conversationConnectingProvider` shows a connecting affordance during the connect window.
4. **`transcription`** — transcript only, no translation (skips Soniox `translation` config).
5. **`quick`** — press-and-hold "walkie-talkie" translator (`QuickPanel`, self-contained). Big text, transcription top / translation bottom, no save/history. Hold the mic to record; the first transcribed word clears the previous result; release stops audio input, lets the trailing translation settle (~700ms), then speaks the full translation via TTS (always on, independent of the global toggle). State lives in `quick_provider.dart` (`quickTranscript` / `quickTranslation` — single growing strings, not history lists).

---

## Target Languages

Twelve languages in `TargetLanguage` enum: **Vietnamese, English, Turkish, Chinese, Korean, Japanese, Thai, Malay, Russian, Indonesian, Arabic, Persian**. Each has a `displayName` and ISO `code`. TTS support matches the locale map in `tts_service.dart`.

**Source language** is also selectable (left side, `sourceLanguageProvider`; `null` = **Any**/auto-detect). A pinned source is sent to Soniox as a `language_hints` entry (`SourceLanguageSelector`), enabling e.g. English → Vietnamese. Applies to line-by-line, split, and quick modes; conversation has its own two-language slots. While recording with "Any", the box shows the detected language.

---

## Architecture Notes

### Navigation
- `MainScreen` is the only route (behind the one-time consent gate).
- History: modal bottom sheet (`HistorySheet`) — list + inline detail + audio player.
- Save flow: save → open history sheet with the saved session pre-selected.
- Purchase and TTS settings are modal sheets/dialogs.

### 3-State Bottom Button Flow
1. **Idle:** History, Mic, Check (unhighlighted)
2. **Recording:** Stop only (history + check hidden)
3. **PostRecording:** Trash (red), Mic, Check (highlighted)

### Audio Recording
- PCM chunks stream to a temp file on disk (one write per 100ms chunk tick — never accumulate audio in memory).
- On save: 44-byte WAV header + PCM → file in app documents → path in `sessions.audio_path`.
- On delete: audio file is removed from disk.
- **Word timestamps** captured per utterance and saved per-line as JSON in `sessions.timestamps_json` for line-by-line audio scrubbing.
- **Capture-failure recovery:** the record engine dies permanently on its first bad AudioRecord read (e.g. audioserver restart) and reports it async on its state stream. `onCaptureError` triggers an in-place restart (2s spurious-error grace, ≤2 attempts/min); if that fails the session is stopped through the normal per-mode path so the UI never claims to record silence. `AudioService.start()`/`stop()` are single-flight + stop-generation-guarded: an abandoned start (resume restart racing a Stop tap) can never bring capture live after the stop, and stop() skips the native call when capture already died (a dead recorder never answers, which would burn the 3s timeout).

### Soniox Translation & Reconnect
- Translation via Soniox `translation` config: `{"type": "one_way", "target_language": "<code>"}`.
- When target == source (e.g. Korean→Korean), transcription is copied into the translation panel.
- **Rotation timer:** WS is rotated every 10 minutes to prevent translation model degradation in long sessions; `contextText` (last 10 history lines) is replayed to keep continuity.
- **Reconnect:** up to 50 attempts; audio buffered (capped at 30s) during reconnection.
- **Optimistic start (ALL modes):** `_startRecording`, `_startQuickRecording`, and `_startConversationSession` do NOT await `connect()` — the mic starts and the UI flips to recording immediately (~200ms); the proxy handshake completes in the background while speech buffers (30s cap) and flushes only into a proven-live socket. `connect()` must be *invoked* before `_audioService.start()` (it synchronously clears the audio buffer before its first await). Start-time connection failures fall into the same reconnect/backoff path as a mid-session drop. Quick/Conversation stops first await the stored connect future (8s cap) so a fast press-release/stop-tap can't finalize a not-yet-open socket and drop the buffered speech.
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
- **All session-sized JSON work runs off the UI isolate via `compute()`** — autosave encode (`_encodeAutosaveDraft`), restore decode (`_decodeAutosaveDraft`), and save-path timestamp encode (`_encodeSessionTimestamps`). An hour-long draft is a multi-MB payload with tens of thousands of word timestamps; inline (de)serialization froze launch/save frames.

### Identity & Customer ID
- `UserService` registers the device on first launch (hardware ID for stable identity), generates an 8-char code, fetches an auth token.
- The code is still called `friendCode` internally (pref key + server field), but the friend/live-session feature was removed (2026-07); the code now surfaces only as the **customer ID** in the Add More Time purchase sheet, with tap-to-copy, for support/purchase enquiries.
- Activity reporting: `UserService.reportActivity('event_name', metadata)` for analytics (app_open, recording_start/stop, session_save, …).

### Theme (light/dark)
- `darkModeProvider` (`theme_provider.dart`) — toggle button in the main-screen header (sun/moon icon), persisted in SharedPreferences (`dark_mode`), **default light, independent of the OS setting**.
- Colors resolve through `AppConstants` static **getters** switched by `AppConstants.isDark` (set in `main()` and in `SilsiganApp.build` before the tree builds). `MainScreen` watches the provider so the whole subtree rebuilds on toggle; `SilsiganApp` swaps MaterialApp `ThemeData` (dialogs/popup menus) and the status-bar icon brightness.
- When adding UI: never mark a widget `const` if it references an `AppConstants` color (it would be canonicalized and skip theme rebuilds). The conversation top half keeps its teal identity in both themes; mic/save-active surfaces invert (pair `micButtonColor` with `micIconColor`, `saveButtonActiveColor` with `saveButtonActiveIconColor`).

### Auto-scroll (all streaming panels)
- Panel auto-follow goes through `_followTail` (line-by-line / transcript) / `_followNewest` (conversation, reversed lists): **skip when the gap is <1px** (most token updates don't change the extent — restarting a scroll activity ~10×/s for an hour was a measurable heat source), **`jumpTo` when the gap exceeds 2 viewports** (animating after a screen-off stint forces layout of every row flown past — a multi-second stall), animate the small in-between deltas as before. Preserve this shape when touching scroll code.

### Background Recording
- Android: `flutter_foreground_task` foreground service (`foregroundServiceType="microphone"` + wake lock, low-importance notification) keeps capture + WS alive while backgrounded.
- The plugin's service is sticky (survives — and its task-removal path resurrects it after — swipe-from-recents, while the Activity's FlutterEngine dies, so recording is dead anyway). `main()` calls `BackgroundService.reapZombieService()` to stop any leftover service at launch; `startRecordingService` awaits an in-flight reap so a fast mic tap can't race it.
- iOS: `UIBackgroundModes: audio` (Info.plist) + flutter_sound's active playAndRecord session keep capture + WS alive while backgrounded — no foreground service. Force-quit or an audio interruption (phone call, Siri) still stops capture.
- App lifecycle: `paused` triggers autosave + sets `_wasPaused`; on `resumed` (if `_wasPaused`, filtering transient `inactive`), audio is restarted ONLY when capture actually died (`AudioService.isCapturingHealthy` — no recorder data in the last 2s). A session that survived the background stint is left untouched, so reopening causes no restart hitch or audio gap.

### Purchases
- RevenueCat package identifiers: `hours_1`, `hours_5`, `hours_10`, `hours_30`, `hours_50` (60, 300, 600, 1800, 3000 minutes respectively).
- iOS only — Android shows mock UI with "not available" snackbar.
- Successful purchase → POST to Render to credit minutes → refresh `_usedSeconds` / `_limitMinutes`.
- Pending purchases (Apple credited but server failed) are persisted and retried on next launch.

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
- **No separate routes** — single screen + modal bottom sheets.

---

## UI Design

- Light theme (default): bg `#EAEAEA`, panels `#FCFCFC`, text `#111111`/`#333333`. Dark palette mirrors it (`#161618`/`#232326`/`#F2F2F3`) via the AppConstants getters — see "Theme (light/dark)" above.
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
