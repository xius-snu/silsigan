# Project Spec: Silsigan — Real-Time Speech Translation App
**Version:** 3.0
**Framework:** Flutter (iOS + Android)
**Target Devices:** iPhone (iOS 16+) and Android (API 24+)

---

## Figma Design Reference
**Figma Link:** https://www.figma.com/design/J5lQW4PqaxOhBiR2vCqrqc/App-MCP?node-id=116-3&m=dev

All UI implementation must reference this Figma file for visual design, spacing, colors, and component structure.

---

## 1. What This App Does

The user opens the app, presses a button, and speaks. Two text panels update live:
- **Top panel:** Transcription appears word-by-word as the user speaks (auto-detected language)
- **Bottom panel:** Translation streams in token-by-token via Soniox one-way translation

Supports multiple target languages: Vietnamese, English, Turkish, Korean.
Audio recordings can be saved alongside transcripts and played back later.

No file uploads. No batch processing. Everything is live, streaming, real-time.

---

## 2. Complete Tech Stack

| Layer | Technology | Reason |
|---|---|---|
| Framework | Flutter (Dart) | Single codebase iOS+Android |
| ASR + Translation | Soniox (`stt-rt-v5`) via WebSocket | Streaming transcription + built-in one-way translation |
| Audio Capture | flutter_sound | Raw PCM16 mic access + WAV file creation |
| State Management | Riverpod | Reactive streams for live text updates |
| WebSocket | web_socket_channel | Soniox WebSocket connection |
| Permissions | permission_handler | Mic permissions iOS + Android |
| Local Storage | sqflite + path_provider | Save session transcripts + audio files locally |
| CI/CD | Codemagic | Automated iOS (TestFlight) + Android builds |

---

## 3. pubspec.yaml Dependencies

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_sound: ^9.2.13
  web_socket_channel: ^3.0.1
  riverpod: ^2.5.1
  flutter_riverpod: ^2.5.1
  permission_handler: ^11.3.1
  convert: ^3.1.1
  sqflite: ^2.3.3
  path_provider: ^2.1.3

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  flutter_launcher_icons: ^0.14.3
```

---

## 4. Environment / API Keys

Store in `.env.json` (never commit, gitignored). Load via `--dart-define`:

```bash
flutter run --dart-define=SONIOX_API_KEY=...
flutter build apk --dart-define=SONIOX_API_KEY=...
```

Access in Dart:
```dart
const sonioxKey = String.fromEnvironment('SONIOX_API_KEY');
```

Only `SONIOX_API_KEY` is required. Soniox handles both transcription and translation.

---

## 5. Soniox API — Real-Time Transcription + Translation

### WebSocket URL
```
wss://stt-rt.soniox.com/transcribe-websocket
```

### Connection Flow
1. Open WebSocket connection (no auth headers needed)
2. Send JSON config message as first frame (includes API key)
3. Stream raw binary audio frames
4. Receive JSON token responses (with transcription + translation tokens)
5. Send `{"type": "finalize"}` to force-finalize pending tokens
6. Close connection to end session

### Config Message
```json
{
  "api_key": "<soniox_api_key>",
  "model": "stt-rt-v5",
  "language_hints": ["ko"],
  "audio_format": "pcm_s16le",
  "sample_rate": 24000,
  "num_channels": 1,
  "enable_endpoint_detection": true,
  "max_endpoint_delay_ms": 2000,
  "translation": {
    "type": "one_way",
    "target_language": "vi"
  }
}
```

Translation config is omitted when target language is Korean (same as source — transcription is copied directly to translation panel).

### Audio Format Requirements
- Format: **PCM16** signed 16-bit little-endian (`pcm_s16le`)
- Sample rate: **24000 Hz**
- Channels: **mono (1)**
- Chunk size: send every **100ms** (~4800 bytes per chunk)
- **Send as raw binary frames** — no base64 encoding

### Token Response Format
```json
{
  "tokens": [
    {
      "text": "안녕하세요",
      "is_final": true,
      "translation_status": "source"
    },
    {
      "text": "Xin chào",
      "is_final": true,
      "translation_status": "translation"
    }
  ]
}
```

### Token Processing
- **`translation_status: "source"`** — transcription token
- **`translation_status: "translation"`** — translated token
- **`is_final: true`** — confirmed text, will not change
- **`is_final: false`** — provisional text, may change (replace, not append)
- **Utterance boundary:** when non-final → all-final, flush pending utterance

---

## 6. App State (Riverpod Providers)

```dart
// Recording state
enum RecordingState { idle, recording, processing, postRecording }
final recordingStateProvider = StateProvider<RecordingState>(...);

// Target language selector
enum TargetLanguage { vietnamese, english, turkish, korean }
final targetLanguageProvider = StateProvider<TargetLanguage>(...);

// Live Korean text (current utterance — draft)
final koreanDraftProvider = StateProvider<String>((ref) => '');

// Finalized Korean lines (history — locked)
final koreanHistoryProvider = StateProvider<List<String>>((ref) => []);

// Live Vietnamese text (currently streaming)
final vietnameseDraftProvider = StateProvider<String>((ref) => '');

// Finalized Vietnamese lines (history)
final vietnameseHistoryProvider = StateProvider<List<String>>((ref) => []);

// Saved sessions list (history)
final sessionHistoryProvider = FutureProvider<List<TranscriptSession>>(...);
```

---

## 7. Data Flow — Step by Step

```
1. User taps mic button
   → Request mic permission
   → Open WebSocket to Soniox (with translation config for target language)
   → Start flutter_sound recording (PCM16, 24kHz, mono)
   → recordingState = recording

2. Every 100ms:
   → Read PCM16 bytes from recorder buffer
   → Send raw binary frame via WebSocket

3. Soniox streams token responses:
   → Source tokens: SET draft (replace, not append)
   → Translation tokens: SET translation draft
   → UI: transcription + translation panels update live

4. Soniox endpoint detection (2000ms pause):
   → Finalize tokens → append to last history line
   → New line only after 4000ms pause (timer-based)

5. User taps stop button:
   → Stop recording, finalize + disconnect WebSocket
   → recordingState = postRecording

6. User taps check (save):
   → Confirmation dialog
   → Save WAV audio file to app documents
   → Insert session to SQLite (text + audio_path)
   → Open history sheet with saved session

7. User taps trash (discard):
   → Confirmation dialog
   → Clear recording buffer + reset state
```

---

## 8. UI Layout

### Main Screen (Single Page)
```
┌─────────────────────────────────────────┐
│  Silsigan                    [status]   │  ← Title + pulsing dot
├─────────────────────────────────────────┤
│  TRANSCRIPTION                    [📋]  │
│  [History lines + live draft]           │  ← Scrollable, selectable
├─────────────────────────────────────────┤
│  TRANSLATION                      [📋]  │
│  [History lines + live draft]           │  ← Scrollable, selectable
├─────────────────────────────────────────┤
│       [Any]    →    [Vietnamese ▼]      │  ← Language selector
│                                         │
│  [History/Trash]  [Mic/Stop]  [Check]   │  ← 3-state button flow
└─────────────────────────────────────────┘
```

### 3-State Button Flow
1. **Idle:** [History] [Mic] [Check (dim)]
2. **Recording:** [hidden] [Stop] [hidden]
3. **PostRecording:** [Trash (red)] [Mic] [Check (bright)]

### History (Bottom Sheet)
- Modal bottom sheet slides up to just below "Silsigan" title
- List view: session cards (date, Korean preview, Vietnamese preview)
- Detail view: inline within same sheet (back arrow to return to list)
- Audio player at bottom: back 10s, play/pause, forward 10s, timeline slider

---

## 9. Audio Pipeline

```dart
// flutter_sound configuration
final recorder = FlutterSoundRecorder();
await recorder.startRecorder(
  toStream: controller.sink,
  codec: Codec.pcm16,
  numChannels: 1,
  sampleRate: 24000,
);

// Timer sends chunks every 100ms
Timer.periodic(Duration(milliseconds: 100), (_) => sendChunk());

// Audio accumulation for WAV saving
_fullRecording.addAll(data);  // accumulate all PCM bytes

// WAV file creation on save
saveRecordingAsWav('session_$timestamp.wav');
```

---

## 10. Local Database — SQLite Schema

### Table: `sessions` (DB version 2)
```sql
CREATE TABLE sessions (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at       TEXT NOT NULL,
  korean_full      TEXT NOT NULL,
  vietnamese_full  TEXT NOT NULL,
  korean_preview   TEXT NOT NULL,
  vietnamese_preview TEXT NOT NULL,
  audio_path       TEXT              -- added in v2 migration
);
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
  final String? audioPath;
}
```

---

## 11. Platform Configuration

### iOS
- Deployment target: **16.0**
- Bundle ID: `com.silsigan.app`
- Info.plist: `NSMicrophoneUsageDescription`
- Podfile: platform `:ios, '16.0'`, `-lc++` linker flag
- project.pbxproj: `OTHER_LDFLAGS = -lc++` on Runner target

### Android
- minSdk: **24** (required by flutter_sound)
- compileSdk: **35**
- Application ID: `com.silsigan.app`
- MainActivity: `com.silsigan.app.MainActivity`
- Java 17 compile options
- AndroidManifest: `RECORD_AUDIO` + `INTERNET` permissions

---

## 12. Error Handling

| Error | Handling |
|---|---|
| Mic permission denied | Dialog with settings link |
| WebSocket connection drops | Auto-reconnect up to 3 times, 1s backoff |
| Soniox API error | Snackbar with error message |
| No internet | Disable Start button |
| DB write fails | Snackbar "Save failed — try again", keep post-recording state |
| Empty session | Disable Save button |

---

## 13. File Structure

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
│   ├── target_language_provider.dart
│   └── session_history_provider.dart
├── services/
│   ├── soniox_realtime_service.dart
│   ├── audio_service.dart
│   └── database_service.dart
├── ui/
│   ├── screens/
│   │   └── main_screen.dart
│   └── widgets/
│       ├── transcript_panel.dart
│       ├── record_button.dart
│       ├── save_discard_row.dart
│       ├── session_card.dart
│       ├── history_sheet.dart
│       └── status_bar.dart
└── utils/
    ├── audio_utils.dart
    └── constants.dart
```

---

## 14. Constants (utils/constants.dart)

```dart
class AppConstants {
  // Soniox
  static const sonioxRealtimeUrl = 'wss://stt-rt.soniox.com/transcribe-websocket';
  static const sonioxModel = 'stt-rt-v5';
  static const transcriptionLanguage = 'ko';

  // Audio
  static const sampleRate = 24000;
  static const numChannels = 1;
  static const chunkIntervalMs = 100;
  static const audioFormat = 'pcm_s16le';
  static const endpointDelayMs = 2000;
  static const newLinePauseMs = 4000;

  // UI design tokens
  static const Color bgColor = Color(0xFFEAEAEA);
  static const Color panelColor = Color(0xFFFCFCFC);
  static const Color textPrimary = Color(0xFF111111);
  static const Color textSecondary = Color(0xFF333333);
  // ... button colors, font sizes, dimensions
}
```

---

## 15. Build & Deploy

```bash
# Debug
flutter run --dart-define=SONIOX_API_KEY=...

# Release APK
flutter build apk --dart-define=SONIOX_API_KEY=...

# iOS: built via Codemagic with SONIOX_API_KEY as env var
# TestFlight distribution for beta testing
```

### Version Bumping
- `pubspec.yaml`: `version: 1.0.0+N`
- Bump `+N` for each App Store Connect upload

---

## 16. What NOT to Build (v1)

- No user accounts or auth
- No cloud sync — all data stays local
- No export to PDF/CSV
- No editing saved transcripts
- No speaker diarization
- No offline mode
- No settings screen
- No TTS (text-to-speech output)
