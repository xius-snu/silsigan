# Silsigan — Korean → Vietnamese Live Translation App

## Project Overview

Real-time Korean speech → Vietnamese translation app built with Flutter. User speaks Korean, sees live transcript, and gets streaming Vietnamese translations powered by Soniox (ASR) and Claude API (translation).

**Spec file:** `korean_vietnamese_live_translation_spec.md`

---

## Tech Stack

- **Framework:** Flutter (Dart) — iOS 16+ / Android 14+
- **Korean ASR:** Soniox (`stt-rt-v4`) via WebSocket
- **Translation:** Anthropic Claude API (`claude-sonnet-4-5`) via SSE streaming
- **Audio:** `flutter_sound` — PCM16 (pcm_s16le), 24kHz, mono
- **State:** Riverpod
- **Storage:** sqflite (local SQLite)

---

## API Keys

Stored in `.env` file (never committed). Loaded via `--dart-define`:

```bash
flutter run \
  --dart-define=SONIOX_API_KEY=... \
  --dart-define=ANTHROPIC_API_KEY=sk-ant-...
```

Access in Dart: `String.fromEnvironment('SONIOX_API_KEY')`

The `.env` file contains both `SONIOX_API_KEY` and `ANTHROPIC_API_KEY`.

---

## Implementation Plan

### Phase 1: Project Scaffold & Configuration
1. Create Flutter project: `flutter create silsigan`
2. Replace `pubspec.yaml` with spec dependencies (flutter_sound, web_socket_channel, http, riverpod, flutter_riverpod, permission_handler, sqflite, path_provider)
3. Create the full `lib/` directory structure per spec section 15
4. Set up `utils/constants.dart` with all API URLs, model names, audio config
5. Configure platform permissions:
   - iOS: `NSMicrophoneUsageDescription` in Info.plist
   - Android: `RECORD_AUDIO` + `INTERNET` in AndroidManifest.xml, `minSdkVersion 21`
6. Set up `app.dart` with MaterialApp + ProviderScope + light theme + routing

### Phase 2: Data Layer
7. Create `models/transcript_session.dart` — data class with `toMap()`/`fromMap()`
8. Create `services/database_service.dart` — SQLite singleton, `CREATE TABLE sessions`, CRUD methods (getAllSessions, getSession, insertSession, deleteSession)
9. Create all Riverpod providers:
   - `recording_provider.dart` — RecordingState enum (idle/recording/processing/postRecording)
   - `transcript_provider.dart` — koreanDraft + koreanHistory
   - `translation_provider.dart` — vietnameseDraft + vietnameseHistory
   - `session_history_provider.dart` — FutureProvider loading from DB

### Phase 3: Core Services
10. Create `services/audio_service.dart`:
    - Init flutter_sound recorder (PCM16, 24kHz, mono)
    - Stream audio to a buffer
    - Timer.periodic(100ms) reads buffer, sends raw Uint8List to callback
    - Start/stop methods
11. Create `services/soniox_realtime_service.dart`:
    - WebSocket connect to `wss://stt-rt.soniox.com/transcribe-websocket`
    - Send JSON config on connect (api_key, model, language_hints, audio_format, endpoint detection)
    - Send raw binary audio frames (no base64)
    - Parse token responses with `is_final` flag:
      - Non-final tokens → `onTranscriptionDraft` callback (replaces draft, not append)
      - Final tokens → accumulate in pending utterance
      - Utterance boundary (non-final→all-final) → `onTranscriptionCompleted` callback
    - `finalize()` to force-finalize pending tokens on stop
    - Auto-reconnect (up to 3 times, 1s backoff)
12. Create `services/claude_translation_service.dart`:
    - POST to Claude Messages API with `stream: true`
    - Parse SSE `data:` lines for `content_block_delta` events
    - Extract `delta.text` → callback for streaming tokens
    - Handle `message_stop` → completion callback
    - System prompt from spec section 6

### Phase 4: UI — Main Transcription Screen
13. Create `widgets/transcript_panel.dart`:
    - Scrollable panel showing history lines (60% opacity) + draft line (full opacity)
    - Auto-scroll to bottom on new content (unless user scrolled up manually)
    - Korean panel: blinking cursor `|` on draft
    - Vietnamese panel: `...` suffix while waiting, then streaming text
14. Create `widgets/record_button.dart`:
    - Idle → shows mic icon "Start"
    - Recording → shows stop icon "Stop"
    - PostRecording → hidden (replaced by save/discard)
15. Create `widgets/save_discard_row.dart`:
    - [✕ Discard] and [✓ Save] buttons
    - Save: build TranscriptSession, insert to DB, invalidate history provider, navigate to History
    - Discard: clear all providers, reset to idle
16. Create `widgets/status_bar.dart` — recording/processing indicator
17. Create `screens/main_screen.dart`:
    - Compose: top bar, Korean panel, divider, Vietnamese panel, bottom action bar
    - Wire up record button to start/stop audio+websocket+translation pipeline
    - Handle PostRecording state: wait for in-flight Claude stream before showing save/discard

### Phase 5: UI — History & Detail Screens
18. Create `widgets/session_card.dart` — date+time, Korean preview, Vietnamese preview
19. Create `screens/history_screen.dart`:
    - ListView of session cards, newest first
    - Tap card → navigate to detail screen
20. Create `screens/session_detail_screen.dart`:
    - Full Korean + Vietnamese transcript, scrollable, read-only
    - Delete button with confirmation dialog
    - Back button returns to history list

### Phase 6: Integration & Error Handling
21. Wire the full data flow:
    - Start: permission → websocket → audio → streaming loop
    - Stop: stop audio → finalize → close websocket → wait for Claude → postRecording
    - Save/Discard: DB insert or clear
22. Implement error handling:
    - Mic permission denied → dialog with settings link
    - WebSocket drops → auto-reconnect (3x, 1s backoff)
    - Claude fails → "[Translation unavailable]" placeholder
    - No internet → banner + disable Start
    - DB write fail → snackbar + retry
    - Empty session → disable Save button
23. Final polish:
    - Light theme matching Figma
    - Font size ≥ 18sp
    - Gotchas: sample rate verification, iOS audio session, auto-scroll logic, sqflite singleton pattern, navigation invalidation, PostRecording Claude wait

---

## File Structure

```
lib/
├── main.dart
├── app.dart
├── models/
│   └── transcript_session.dart
├── providers/
│   ├── recording_provider.dart
│   ├── transcript_provider.dart
│   ├── translation_provider.dart
│   └── session_history_provider.dart
├── services/
│   ├── soniox_realtime_service.dart
│   ├── audio_service.dart
│   ├── claude_translation_service.dart
│   └── database_service.dart
├── ui/
│   ├── screens/
│   │   ├── main_screen.dart
│   │   ├── history_screen.dart
│   │   └── session_detail_screen.dart
│   └── widgets/
│       ├── transcript_panel.dart
│       ├── record_button.dart
│       ├── save_discard_row.dart
│       ├── session_card.dart
│       └── status_bar.dart
└── utils/
    ├── audio_utils.dart
    └── constants.dart
```

---

## Key Design Decisions

- **API keys via `--dart-define`** — no .env file in bundle, no runtime file reading. Keys stored in `.env` for convenience.
- **SQLite (sqflite)** — local-only storage, no cloud sync, singleton pattern
- **Riverpod StateProviders** — reactive streams drive UI updates from WebSocket/SSE events
- **PCM16 at 24kHz** — compatible with Soniox (accepts any sample rate with `pcm_s16le`)
- **Soniox endpoint detection** — auto-finalizes tokens after speech pause (600ms delay), triggers Claude translation
- **One Claude call per completed utterance** — triggered when Soniox finalizes tokens at an endpoint boundary

---

## What NOT to Build (v1)

No auth, no cloud sync, no export, no transcript editing, no speaker diarization, no offline mode, no settings screen, no TTS.

---

## Build & Run

```bash
# Run with API keys
flutter run --dart-define=SONIOX_API_KEY=... --dart-define=ANTHROPIC_API_KEY=sk-ant-...

# Build release
flutter build apk --dart-define=SONIOX_API_KEY=... --dart-define=ANTHROPIC_API_KEY=sk-ant-...
flutter build ios --dart-define=SONIOX_API_KEY=... --dart-define=ANTHROPIC_API_KEY=sk-ant-...
```

---

## Coding Conventions

- Dart formatting: `dart format .` before commits
- Use `const` constructors where possible
- Riverpod: prefer `StateProvider` for simple state, `FutureProvider` for async DB queries
- Services: expose clean start/stop/dispose interfaces
- Error handling: fail gracefully, never crash — show user-friendly messages
- All UI references should follow the Figma design: https://www.figma.com/design/J5lQW4PqaxOhBiR2vCqrqc/App-MCP?node-id=116-3&m=dev
