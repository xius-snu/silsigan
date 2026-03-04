# Project Spec: Korean → Vietnamese Live Translation App
**Version:** 2.0
**Framework:** Flutter (iOS + Android)
**Target Devices:** iPhone (iOS 16+) and Samsung Galaxy S26 Ultra (Android 14+)

---

## Figma Design Reference
**Figma Link:** https://www.figma.com/design/J5lQW4PqaxOhBiR2vCqrqc/App-MCP?node-id=116-3&m=dev

All UI implementation must reference this Figma file for visual design, spacing, colors, and component structure. Use the dev mode link (`?m=dev`) to inspect exact values.

---

## 1. What This App Does

The user opens the app, presses a button, and speaks Korean. Two text panels update live:
- **Top panel:** Korean transcript appears word-by-word as the user speaks
- **Bottom panel:** Vietnamese translation streams in token-by-token as each Korean sentence completes

No file uploads. No batch processing. Everything is live, streaming, real-time.

---

## 2. Complete Tech Stack

| Layer | Technology | Reason |
|---|---|---|
| Framework | Flutter (Dart) | Single codebase iOS+Android, no JS bridge overhead for audio |
| Korean ASR | Soniox (`stt-rt-v4`) via WebSocket | Best Korean streaming accuracy (~4.3% WER), token-based output with is_final flag |
| Vietnamese Translation | Anthropic Claude API (`claude-sonnet-4-5`) via SSE streaming | Best KO→VI quality, streaming tokens, register-aware |
| Audio Capture | flutter_sound | Raw PCM16 mic access on both platforms |
| State Management | Riverpod | Reactive streams for live text updates |
| WebSocket | web_socket_channel | Soniox WebSocket connection |
| HTTP/SSE | http + dart:async | Claude API streaming |
| Permissions | permission_handler | Mic permissions iOS + Android |
| Local Storage | sqflite + path_provider | Save session transcripts as structured records locally |

---

## 3. pubspec.yaml Dependencies

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_sound: ^9.2.13
  web_socket_channel: ^3.0.1
  http: ^1.2.0
  riverpod: ^2.5.1
  flutter_riverpod: ^2.5.1
  permission_handler: ^11.3.1
  sqflite: ^2.3.3        # local SQLite database for transcript history
  path_provider: ^2.1.3  # get local file system path for DB

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
```

---

## 4. Environment / API Keys

Store in `.env` file (never commit). Load via `--dart-define`:

```
SONIOX_API_KEY=...
ANTHROPIC_API_KEY=sk-ant-...
```

Access in Dart:
```dart
const sonioxKey = String.fromEnvironment('SONIOX_API_KEY');
const anthropicKey = String.fromEnvironment('ANTHROPIC_API_KEY');
```

---

## 5. Soniox API — Real-Time Transcription

### WebSocket URL
```
wss://stt-rt.soniox.com/transcribe-websocket
```

### Connection Flow
1. Open WebSocket connection (no auth headers needed)
2. Send JSON config message as first frame
3. Stream raw binary audio frames
4. Receive JSON token responses
5. Send `{"type": "finalize"}` to force-finalize pending tokens
6. Send empty frame or close connection to end session

### Config Message (send immediately after connection opens)
```json
{
  "api_key": "<soniox_api_key>",
  "model": "stt-rt-v4",
  "language_hints": ["ko"],
  "audio_format": "pcm_s16le",
  "sample_rate": 24000,
  "num_channels": 1,
  "enable_endpoint_detection": true,
  "max_endpoint_delay_ms": 600
}
```

### Audio Format Requirements
- Format: **PCM16** signed 16-bit little-endian (`pcm_s16le`)
- Sample rate: **24000 Hz**
- Channels: **mono (1)**
- Chunk size: send every **100ms** (~4800 bytes per chunk)
- **Send as raw binary frames** — no base64 encoding needed

### Token Response Format
```json
{
  "tokens": [
    {
      "text": "안녕하세요",
      "start_ms": 600,
      "end_ms": 1200,
      "confidence": 0.97,
      "is_final": true
    },
    {
      "text": " 오늘",
      "start_ms": 1200,
      "end_ms": 1500,
      "confidence": 0.85,
      "is_final": false
    }
  ],
  "final_audio_proc_ms": 1200,
  "total_audio_proc_ms": 1500
}
```

### Token Processing Model
- **`is_final: true`** — Confirmed text. Will never change. Append to confirmed buffer.
- **`is_final: false`** — Provisional text. May change or disappear. Replace previous provisional display.
- **Utterance boundary detection:** When non-final tokens transition to all-final (endpoint detected by Soniox), this signals a completed utterance → trigger Claude translation.

### Error Response
```json
{
  "tokens": [],
  "error_code": 503,
  "error_message": "Error description"
}
```

### Session Finished Response
```json
{
  "tokens": [],
  "finished": true
}
```

---

## 6. Claude API — Streaming Vietnamese Translation

Trigger one Claude API call per **completed** Korean utterance (from utterance boundary detection above).

### Endpoint
```
POST https://api.anthropic.com/v1/messages
```

### Headers
```dart
{
  'x-api-key': anthropicKey,
  'anthropic-version': '2023-06-01',
  'content-type': 'application/json',
  'accept': 'text/event-stream',  // SSE streaming
}
```

### Request Body
```json
{
  "model": "claude-sonnet-4-5",
  "max_tokens": 1024,
  "stream": true,
  "system": "You are a live Korean-to-Vietnamese interpreter. Rules:\n1. Translate naturally and fluently — not word-for-word literally\n2. Match speech register: formal Korean (합쇼체/해요체) → formal Vietnamese, casual Korean (해체/반말) → casual Vietnamese\n3. Output ONLY the Vietnamese translation. No explanations, no notes, no preamble\n4. Preserve proper nouns, brand names, and English words as-is\n5. If input contains mixed Korean-English (code-switching), translate the Korean parts and keep English words unchanged\n6. Keep translations concise and natural-sounding",
  "messages": [
    {
      "role": "user",
      "content": "<completed Korean transcript here>"
    }
  ]
}
```

### SSE Stream Parsing
Parse `data:` lines from the SSE stream:
```dart
// Listen for events of type: content_block_delta
// Extract: event.delta.text → append to Vietnamese text buffer

// Stream ends on: message_stop event
```

### SSE Event Structure
```json
{
  "type": "content_block_delta",
  "delta": {
    "type": "text_delta",
    "text": "Xin chào"
  }
}
```

---

## 7. App State (Riverpod Providers)

```dart
// Recording state
enum RecordingState { idle, recording, processing, postRecording }
final recordingStateProvider = StateProvider<RecordingState>(...);

// Live Korean text (current utterance being spoken — draft)
final koreanDraftProvider = StateProvider<String>((ref) => '');

// Finalized Korean lines (history — locked, won't change)
final koreanHistoryProvider = StateProvider<List<String>>((ref) => []);

// Live Vietnamese text (currently streaming)
final vietnameseDraftProvider = StateProvider<String>((ref) => '');

// Finalized Vietnamese lines (history)
final vietnameseHistoryProvider = StateProvider<List<String>>((ref) => []);

// Saved sessions list (history page)
final sessionHistoryProvider = FutureProvider<List<TranscriptSession>>((ref) async {
  return await DatabaseService.instance.getAllSessions();
});
```

---

## 8. Data Flow — Step by Step

```
1. User taps [Start] button
   → Request mic permission (permission_handler)
   → Open WebSocket to Soniox
   → Send config JSON (api_key, model, language_hints, audio_format, endpoint detection)
   → Start flutter_sound mic recording (PCM16, 24kHz, mono)
   → recordingState = recording

2. Every 100ms audio timer fires:
   → Read PCM16 bytes from flutter_sound buffer
   → Send raw binary frame via WebSocket (no base64)

3. Soniox streams token responses:
   → Non-final tokens: SET koreanDraftProvider (replace, not append)
   → Final tokens: accumulate in pending utterance buffer
   → UI updates: Korean top panel shows growing text live

4. Soniox endpoint detection fires (pause detected):
   → All pending non-final tokens become final
   → Utterance boundary detected
   → Move pending utterance → append to koreanHistoryProvider
   → Clear koreanDraftProvider
   → Trigger Claude API call with completed utterance

5. Claude SSE stream begins:
   → Each content_block_delta: append delta.text to vietnameseDraftProvider
   → UI updates: Vietnamese bottom panel streams text live

6. Claude stream ends (message_stop):
   → Move vietnameseDraftProvider value → append to vietnameseHistoryProvider
   → Clear vietnameseDraftProvider

7. User taps [Stop] button:
   → Stop flutter_sound recording
   → Send finalize command to Soniox (force-finalize pending tokens)
   → Close WebSocket connection
   → If Claude still streaming: wait for completion
   → recordingStateProvider → PostRecording

8. User taps [✓ Save]:
   → Build TranscriptSession from koreanHistoryProvider + vietnameseHistoryProvider
   → Insert into SQLite sessions table
   → Navigate to History page (session appears at top)
   → Clear all draft + history providers → reset to idle

9. User taps [✕ Discard]:
   → Clear all draft + history providers → reset to idle
   → Nothing saved
```

---

## 9. UI Layout

### Screen 1 — Main Transcription Screen (Live)
```
┌─────────────────────────────────────────┐
│  [🇰🇷 Korean]              [📋 History]  │  ← Top bar + history nav button
├─────────────────────────────────────────┤
│                                         │
│  [Finalized Korean line 1]              │  ← Locked, grey text, scrolls up
│  [Finalized Korean line 2]              │
│  [Live draft Korean text...]            │  ← Active, white/black bold text
│                                         │
├─────────────────────────────────────────┤  ← Divider
│                                         │
│  [Finalized Vietnamese line 1]          │  ← Locked, grey text
│  [Finalized Vietnamese line 2]          │
│  [Streaming Vietnamese text...]         │  ← Active, streaming token by token
│                                         │
└─────────────────────────────────────────┘
│  [🗑️ Discard]   [🎤 Start / ⏹ Stop]   │  ← Bottom action bar
└─────────────────────────────────────────┘
```

### Post-Recording State (after tapping Stop)
When the user taps Stop, the recording ends and the mic button transforms into a two-button confirmation row:

```
┌─────────────────────────────────────────┐
│  Full transcript visible (scrollable)   │
│  Both Korean + Vietnamese panels        │
│  frozen — no more updates               │
└─────────────────────────────────────────┘
│       [✕ Discard]    [✓ Save]          │  ← Confirm or discard session
└─────────────────────────────────────────┘
```

- **✕ Discard:** clears all text, resets to idle state, nothing saved
- **✓ Save:** saves the session to local SQLite DB, navigates to History page, session appears at top

### Screen 2 — History Page
```
┌─────────────────────────────────────────┐
│  ← Back          [📋 History]           │
├─────────────────────────────────────────┤
│  March 4, 2026 — 14:32                  │
│  "안녕하세요 오늘 회의를..."            │  ← Korean preview (first line)
│  "Xin chào, hôm nay cuộc họp..."       │  ← Vietnamese preview (first line)
├─────────────────────────────────────────┤
│  March 4, 2026 — 11:05                  │
│  "감사합니다 잘 부탁드립니다..."        │
│  "Cảm ơn, rất mong được..."            │
├─────────────────────────────────────────┤
│  March 3, 2026 — 09:17                  │
│  ...                                    │
└─────────────────────────────────────────┘
```

- Sessions listed **newest first** (reverse chronological)
- Each card shows: date+time, first Korean line preview, first Vietnamese line preview
- Tap a card → opens Screen 3

### Screen 3 — Saved Session Detail View
```
┌─────────────────────────────────────────┐
│  ← Back    March 4, 2026 — 14:32   [🗑] │  ← Delete this session
├─────────────────────────────────────────┤
│  [🇰🇷 Korean]                           │
│  안녕하세요 오늘 회의를 시작하겠습니다  │
│  이번 분기 매출은 전년 대비...          │
│  ...                                    │
├─────────────────────────────────────────┤
│  [🇻🇳 Vietnamese]                       │
│  Xin chào, chúng ta sẽ bắt đầu cuộc    │
│  họp hôm nay. Doanh thu quý này so      │
│  với năm ngoái...                       │
│  ...                                    │
└─────────────────────────────────────────┘
```

- Full transcript, both languages, scrollable
- Read-only — no editing
- Delete button (🗑) removes session from DB after confirmation dialog

### UI Behavior Rules
- Both panels are **independently scrollable** but **auto-scroll to bottom** when new content arrives during live recording
- In detail view, panels scroll together (linked scroll)
- Draft text (currently live) shown in **full opacity**
- Finalized history lines shown in **60% opacity** (greyed out)
- Korean draft text: show a blinking cursor `|` at the end while streaming
- Vietnamese draft text: show `...` suffix while waiting for Claude, replace with streaming text when it starts
- Font size: minimum 18sp for readability
- Light theme matching Figma design

---

## 10. Audio Pipeline — Flutter Implementation

```dart
// flutter_sound configuration
final recorder = FlutterSoundRecorder();
await recorder.openRecorder();

await recorder.startRecorder(
  toStream: audioStreamController.sink,
  codec: Codec.pcm16,
  numChannels: 1,
  sampleRate: 24000,
);

// Timer to batch and send chunks every 100ms
Timer.periodic(Duration(milliseconds: 100), (timer) {
  if (audioBuffer.isNotEmpty) {
    final bytes = Uint8List.fromList(audioBuffer);
    // Send raw binary — no base64 encoding needed for Soniox
    webSocket.sink.add(bytes);
    audioBuffer.clear();
  }
});
```

---

## 11. Local Database — SQLite Schema

### Table: `sessions`
```sql
CREATE TABLE sessions (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at  TEXT NOT NULL,           -- ISO 8601: "2026-03-04T14:32:00"
  korean_full TEXT NOT NULL,           -- Full Korean transcript (all lines joined by \n)
  vietnamese_full TEXT NOT NULL,       -- Full Vietnamese transcript (all lines joined by \n)
  korean_preview TEXT NOT NULL,        -- First 80 chars of Korean (for history list card)
  vietnamese_preview TEXT NOT NULL     -- First 80 chars of Vietnamese (for history list card)
);
```

### Save Flow (on ✓ Save tap)
```dart
final session = TranscriptSession(
  createdAt: DateTime.now().toIso8601String(),
  koreanFull: koreanHistory.join('\n'),
  vietnameseFull: vietnameseHistory.join('\n'),
  koreanPreview: koreanHistory.first.take(80),
  vietnamesePreview: vietnameseHistory.first.take(80),
);
await db.insert('sessions', session.toMap());
```

### Session Model
```dart
class TranscriptSession {
  final int? id;
  final String createdAt;
  final String koreanFull;
  final String vietnameseFull;
  final String koreanPreview;
  final String vietnamesePreview;
}
```

### Queries
```dart
// Load all sessions (history page — newest first)
final sessions = await db.query('sessions', orderBy: 'created_at DESC');

// Load single session (detail view)
final session = await db.query('sessions', where: 'id = ?', whereArgs: [id]);

// Delete session
await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
```

---

### iOS (ios/Runner/Info.plist)
```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to transcribe Korean speech in real time.</string>
```

### Android (android/app/src/main/AndroidManifest.xml)
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
```

### Android (android/app/build.gradle)
```gradle
minSdkVersion 21
```

---

## 14. Error Handling

| Error | Handling |
|---|---|
| Mic permission denied | Show dialog explaining why permission is needed, link to settings |
| WebSocket connection drops | Auto-reconnect up to 3 times with 1s backoff, show "Reconnecting..." |
| Soniox API error | Log error, show snackbar "Transcription error — tap to retry" |
| Claude API fails | Show "[Translation unavailable]" in Vietnamese panel, continue Korean transcription |
| No internet | Show "No internet connection" banner, disable Start button |
| DB write fails on Save | Show snackbar "Save failed — try again", keep post-recording state active so user can retry |
| Empty session on Save | If both Korean and Vietnamese history are empty, disable ✓ Save button |

---

## 15. File Structure

```
lib/
├── main.dart
├── app.dart                              # MaterialApp + Riverpod ProviderScope + routing
├── models/
│   └── transcript_session.dart          # TranscriptSession data class + toMap/fromMap
├── providers/
│   ├── recording_provider.dart          # RecordingState enum + provider
│   ├── transcript_provider.dart         # Korean draft + history providers
│   ├── translation_provider.dart        # Vietnamese draft + history providers
│   └── session_history_provider.dart    # FutureProvider for saved sessions list
├── services/
│   ├── soniox_realtime_service.dart    # WebSocket connection + token processing
│   ├── audio_service.dart              # flutter_sound mic capture + PCM chunking
│   ├── claude_translation_service.dart  # SSE streaming translation
│   └── database_service.dart           # SQLite singleton — CRUD for sessions
├── ui/
│   ├── screens/
│   │   ├── main_screen.dart            # Live transcription screen
│   │   ├── history_screen.dart         # Chronological list of saved sessions
│   │   └── session_detail_screen.dart  # Read-only view of a saved session
│   └── widgets/
│       ├── transcript_panel.dart       # Reusable scrollable text panel
│       ├── record_button.dart          # Start / Stop button
│       ├── save_discard_row.dart       # [✕ Discard] [✓ Save] post-recording buttons
│       ├── session_card.dart           # History list item card
│       └── status_bar.dart             # Recording/processing indicator
└── utils/
    ├── audio_utils.dart                # PCM16 format helpers
    └── constants.dart                  # API URLs, model names, config values
```

---

## 17. Constants (utils/constants.dart)

```dart
class AppConstants {
  // Soniox
  static const sonioxRealtimeUrl =
    'wss://stt-rt.soniox.com/transcribe-websocket';
  static const sonioxModel = 'stt-rt-v4';
  static const transcriptionLanguage = 'ko';

  // Audio
  static const sampleRate = 24000;
  static const numChannels = 1;
  static const chunkIntervalMs = 100;
  static const audioFormat = 'pcm_s16le';
  static const endpointDelayMs = 600;

  // Claude
  static const claudeApiUrl = 'https://api.anthropic.com/v1/messages';
  static const claudeModel = 'claude-sonnet-4-5';
  static const claudeMaxTokens = 1024;

  // UI
  static const draftFontSize = 18.0;
  static const historyOpacity = 0.6;
}
```

---

## 16. What NOT to Build

- No user accounts or auth
- No cloud sync — all data stays local on device
- No export to PDF/CSV (v1)
- No editing saved transcripts
- No speaker diarization (v1)
- No offline mode
- No settings screen (v1)
- No TTS (text-to-speech output)

---

## 18. Known Gotchas

1. **flutter_sound PCM output is 16kHz by default on some Android devices** — explicitly set `sampleRate: 24000` and verify with a log on first chunk
2. **Soniox token model** — non-final tokens REPLACE previous non-final text (don't append). Track `is_final` flag carefully.
3. **Soniox finalize command** — send `{"type": "finalize"}` before closing the WebSocket to ensure all pending tokens are finalized
4. **Claude SSE stream**: parse line by line, skip `event:` lines, only process `data:` lines, stop on `data: [DONE]`
5. **iOS audio session** — configure `AVAudioSession` category to `playAndRecord` with `defaultToSpeaker` option to prevent mic being blocked by other apps
6. **Korean text rendering** — use `TextAlign.left` and ensure the font supports full Hangul range (system font is fine on both platforms)
7. **Auto-scroll** — use `ScrollController` and call `animateTo(controller.position.maxScrollExtent)` after every state update, but only if user hasn't manually scrolled up
8. **sqflite initialization** — open the database once at app startup via a singleton `DatabaseService`, not on each screen. Use `onCreate` to run the CREATE TABLE migration
9. **Navigation after Save** — after inserting to DB, invalidate `sessionHistoryProvider` so the history page refetches fresh data before navigating to it
10. **PostRecording state during Claude streaming** — if the user taps Stop while Claude is still streaming a translation, wait for the current Claude stream to finish before showing the [✕ Discard][✓ Save] row, so the saved Vietnamese text is complete
11. **Soniox max session** — WebSocket sessions have a 300-minute limit. For long sessions, handle the `finished` event gracefully.
