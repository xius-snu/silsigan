# Silsigan — Real-Time Speech Translation App

## Project Overview

Real-time speech translation app built with Flutter. User speaks in any language (auto-detected), sees live transcript, and gets streaming translations powered by Soniox (ASR + translation). Four display modes (line-by-line, split, conversation, transcription), twelve target languages, a light/dark theme toggle, and optional Google/Apple account sync that pools time and saved recordings across a user's devices.

**Spec file:** `korean_vietnamese_live_translation_spec.md`

---

## Tech Stack

- **Framework:** Flutter (Dart) — iOS 16+ / Android 14+ (API 24+)
- **ASR + Translation:** Soniox (`stt-rt-v5`) via WebSocket — proxied through our own server
- **Audio:** PCM16 (pcm_s16le), 24kHz, mono — captured via `record` on Android/desktop and our own AVAudioEngine plugin on iOS (`ios/Runner/MicCapture.swift`). Speaker (system-audio) capture is WASAPI / ScreenCaptureKit / PulseAudio / MediaProjection on those platforms, and a ReplayKit broadcast extension on iOS (see "Speaker capture on iPhone / iPad"). `flutter_sound` is only used for history playback now. **Do not move Android back to flutter_sound:** its streaming engine polls AudioRecord on the Android platform main thread via a self-reposting runnable whose queue population grows every read — after ~30-60min it saturates the main looper (device heat, hard UI freeze on resume, laggy relaunch that survives swipe-away because the mic FGS keeps the process alive). **Do not move iOS back to flutter_sound's recorder either:** its stream recorder (9.28.0 `AudioRecorderEngine`) ignores `AVAudioEngine.start` errors and reports success, builds its converter from an input format read before the engine starts (a different settled hardware format makes every buffer fail conversion and get dropped), and never handles configuration changes, interruptions or media-services resets. Each of those left the button on Stop with no audio and no error (iPad, 1.1.3). Its `openRecorder` never configured the audio session either, despite what older notes claimed. The session is ours (`CaptureAudioRoute`, plus TTS init).
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
- **Hetzner WS proxy** (`proxy.silsigan.xyz`) — `server/proxy-standalone.js`. Forwards client audio to `wss://stt-rt.soniox.com`, attaches the Soniox key, meters audio bytes, and force-closes WS with code **4005** when the user crosses their usage limit. It logs every Soniox error frame and abnormal close with a masked key, cools down a key Soniox refused (401/402/403: 10 min, 429: 30s) so round-robin stops handing it out, and closes with 4002 (not 4001 "Invalid credentials") when the Render auth check itself fails. **NOT auto-deployed** — manual deploy required (see [Hetzner proxy deploy](memory/reference_hetzner_proxy_deploy.md)).

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

Render env vars: `SONIOX_API_KEYS`, `LIMITED_SONIOX_API_KEYS`, `SONIOX_PRIVATE_KEY`, `DATABASE_URL`, `PUBLIC_ACCESS_DISABLED`, RevenueCat webhook secret, `FIREBASE_SERVICE_ACCOUNT` (optional — support-chat push).

---

## File Structure

```
lib/
├── main.dart                              # Initializes BackgroundService + UserService + PushService
├── app.dart
├── models/
│   ├── transcript_session.dart            # +title, +timestampsJson, +audioPath
│   ├── word_timestamp.dart                # Per-word ms offsets for audio scrubbing
│   └── support_message.dart               # Support chat message / thread summary
├── providers/
│   ├── recording_provider.dart            # idle/recording/processing/postRecording
│   ├── display_mode_provider.dart         # lineByLine/split/conversation/transcription
│   ├── target_language_provider.dart      # 8 languages + sourceLanguageProvider (null = Any)
│   ├── detected_language_provider.dart    # Soniox-detected source language
│   ├── theme_provider.dart                # darkModeProvider (toggle-driven, persisted)
│   ├── transcript_provider.dart           # koreanDraft + koreanHistory (legacy naming)
│   ├── translation_provider.dart          # vietnameseDraft + vietnameseHistory (legacy naming)
│   ├── conversation_provider.dart         # Conversation mode: myLanguage/theirLanguage/messages
│   ├── tts_provider.dart                  # ttsEnabled, ttsRate (0.5–1.5×)
│   ├── account_provider.dart              # AccountState mirror of AccountService
│   └── session_history_provider.dart      # FutureProvider over SQLite
├── services/
│   ├── soniox_realtime_service.dart       # WS to proxy; rotation timer, reconnect, 4005 handling
│   ├── audio_service.dart                 # Capture (record / iOS MicCapture) + WAV file saving
│   ├── tts_service.dart                   # flutter_tts queue, per-language locale map
│   ├── database_service.dart              # SQLite singleton — sessions + autosave_draft
│   ├── user_service.dart                  # Auth, customer ID (friend code), hardware ID, usage
│   ├── sync_service.dart                  # Upload saved sessions to Render
│   ├── purchase_service.dart              # RevenueCat init/purchase/pending retry
│   ├── support_service.dart               # In-app 1:1 support chat HTTP client
│   ├── push_service.dart                  # FCM wrapper (no-op until flutterfire configure)
│   ├── update_service.dart                # Force-update check
│   ├── account_service.dart               # Optional Google/Apple sign-in + merge
│   └── background_service.dart            # Android foreground service (flutter_foreground_task)
├── ui/
│   ├── screens/
│   │   ├── main_screen.dart               # Primary screen — all display modes
│   │   ├── consent_screen.dart            # One-time data-sharing consent gate
│   │   ├── support_chat_screen.dart       # 1:1 support thread (customer or team reply)
│   │   └── support_inbox_screen.dart      # Team inbox (service_admin only)
│   └── widgets/
│       ├── transcript_panel.dart          # Split-mode scrollable panel with copy button
│       ├── line_by_line_panel.dart        # Aligned per-utterance pairs with audio scrubbing
│       ├── conversation_panel.dart        # Chat-bubble UI; two-sided shared toggle mic (two-way)
│       ├── source_language_selector.dart  # Left-side source picker (Any/auto-detect or pinned)
│       ├── record_button.dart             # Animated mic/stop with haptics
│       ├── save_discard_row.dart          # idle/postRecording side buttons
│       ├── history_sheet.dart             # Bottom sheet: list + inline detail + audio player
│       ├── session_card.dart              # History list item
│       ├── status_bar.dart                # Pulsing recording dot + remaining time
│       ├── tts_control_button.dart        # TTS toggle + rate slider
│       └── account_sheet.dart             # Optional account-sync sign-in sheet
└── utils/
    ├── audio_utils.dart
    └── constants.dart                     # serverBaseUrl, proxy URLs, design tokens

server/
├── index.js                               # Render API (Fastify + Postgres)
├── support-chat.js                        # Support threads + FCM push
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

(A press-and-hold `quick` mode existed until 2026-09 and was removed; `loadSavedDisplayMode` falls back to `lineByLine` for the stale persisted name.)

---

## Target Languages

Twelve languages in `TargetLanguage` enum: **Vietnamese, English, Turkish, Chinese, Korean, Japanese, Thai, Malay, Russian, Indonesian, Arabic, Persian**. Each has a `displayName` and ISO `code`. TTS support matches the locale map in `tts_service.dart`.

**Source language** is also selectable (left side, `sourceLanguageProvider`; `null` = **Any**/auto-detect). A pinned source is sent to Soniox as a `language_hints` entry (`SourceLanguageSelector`), enabling e.g. English → Vietnamese. Applies to line-by-line and split modes; conversation has its own two-language slots. While recording with "Any", the box shows the detected language.

---

## Architecture Notes

### Navigation
- `MainScreen` is the only route (behind the one-time consent gate).
- History: modal bottom sheet (`HistorySheet`) — list + inline detail + audio player.
- Save flow: save → open history sheet with the saved session pre-selected.
- Purchase and TTS settings are modal sheets/dialogs.
- Support chat is a pushed page (`SupportChatScreen` / `SupportInboxScreen`) so the keyboard and thread can take the whole screen. The Add More Time sheet is closed before it opens.

### 3-State Bottom Button Flow
1. **Idle:** History, Mic, Check (unhighlighted)
2. **Recording:** Stop only (history + check hidden)
3. **PostRecording:** Trash (red), Mic, Check (highlighted)

### Audio Recording
- PCM chunks stream to a temp file on disk (one write per 100ms chunk tick — never accumulate audio in memory).
- On save: 44-byte WAV header + PCM → file in app documents → path in `sessions.audio_path`.
- On delete: audio file is removed from disk.
- **Word timestamps** captured per utterance and saved per-line as JSON in `sessions.timestamps_json` for line-by-line audio scrubbing.
- **Capture-failure recovery:** the record engine dies permanently on its first bad AudioRecord read (e.g. audioserver restart) and reports it async on its state stream. `onCaptureError` triggers an in-place restart (2s spurious-error grace; only real restarts count toward ≤2/min, so a capture that came back by itself never ends the session); if that fails the session is stopped through the normal per-mode path so the UI never claims to record silence. `AudioService.start()`/`stop()` are single-flight + stop-generation-guarded: an abandoned start (resume restart racing a Stop tap) can never bring capture live after the stop, and stop() skips the native call when capture already died (a dead recorder never answers, which would burn the 3s timeout).
- **iOS capture (`MicCapture` in `ios/Runner/MicCapture.swift`):** MethodChannel `com.silsigan.app/mic_capture` (start/stop) + EventChannel `…/mic_capture/pcm`. `start` configures the session (`CaptureAudioRoute.prepareForCapture`), pins the mic and starts a fresh AVAudioEngine in one main-thread pass, and **throws** on any failure (`MIC_BUSY` when a call or another recorder holds the mic, `MIC_UNAVAILABLE`, `MIC_START_FAILED`), so a dead mic is never reported as started. The tap uses `format: nil`, and the converter follows each buffer's own format. A configuration change, an ended interruption, a media-services reset, or a tap that goes quiet for 2s rebuilds the engine in place. Each rebuild re-checks health first, and at most 3 rebuilds that didn't bring audio back are allowed per 10s. Past that it sends `MIC_LOST`. Interruptions also go to Dart as `{"interrupted": bool}` events on the PCM stream. All of its observers use `queue: nil` and hop to main themselves: with `queue: .main`, NotificationCenter blocks AVAudioEngine's internal queue until main runs the block, which can deadlock against an engine stop/start on main (AVAudioEngine.h warns about this). On the Dart side, `AudioService._checkIosStall` feeds the same `onCaptureError` restart-or-stop path Android uses. It fires after 6s without data or on `MIC_LOST`, only in the foreground, and not during an interruption (capped at 10 min). Backgrounded failures are left to the lifecycle resume path, because iOS won't let a backgrounded app start recording. **A capture restart that throws must end the session** (`_endSessionAfterCaptureLoss`): `start()` has already torn the dead capture down, so `isRecording` is false while the UI still shows Stop.
- **Desktop capture (Windows / macOS / Linux):** the `record` plugins never report a mic that dies mid-session. record_windows answers a Media Foundation read error (unplug, sleep/wake, driver reset) with a plain `stop` state, and record_macos never restarts its AVAudioEngine after a configuration change (input switch, AirPods, sample-rate change). Either way the mic went quiet under a live session. `AudioService._checkDesktopStall` treats 4s without record data (8s before the first buffer, or after a sleep gap in its 1s ticks) as dead and feeds `onCaptureError`. It watches in every lifecycle state, since desktop apps keep running unfocused. Native loopback heals itself instead: the WASAPI thread reopens on device invalidation and follows the default output (falling back to it when a picked device disappears), and macOS restarts an SCStream that ScreenCaptureKit stopped, except a user stop from the menu bar. Loopback isn't watched from Dart because Windows delivers no packets while nothing plays. While capture runs, `DesktopAudioDevices.setKeepAwake` holds `ES_SYSTEM_REQUIRED` (Windows) or a `.userInitiated` activity (macOS), so idle sleep or App Nap can't cut a hands-off session. The display may still turn off.
- **iOS audio route (`CaptureAudioRoute` in `ios/Runner/DesktopAudioCapture.swift`):** capture is pinned to the built-in mic while playback keeps `allowBluetoothA2DP`, so TTS can take AirPods without HFP stealing the input. **A route-change observer must never answer a route change by unconditionally reconfiguring the session.** `setCategory` / `setActive` / `setPreferredInput` each post `routeChangeNotification` themselves, so that is a self-feeding loop: it pegged the platform main thread, starved the `applyCaptureRoute` channel reply, and froze the record button mid-start with the mic already live (orange indicator on, button never flipping to Stop), while Android — whose `AudioDeviceCallback` only fires on real device add/remove — was unaffected. What keeps it bounded, and must stay: `.override` notifications are ignored (that reason is our own `defaultToSpeaker` / `setPreferredInput` echo), the observer runs on the posting thread (`queue: nil`) and re-applies are debounced 300ms onto the main queue, and an observer pass (`configure(activate: false, …)`) is a true no-op when the session already holds the wanted category + preferred input. "Already holds" is compared against what iOS *reported back* after our last `setCategory` and against the last pin we sent, so a session that normalizes options or declines a pin still converges. As a last bound, a circuit breaker stops observer re-applies for 30s after 4 passes in 10s that changed something. Explicit applies (MicCapture start, TTS init) also touch only what differs: every call can land under a live capture engine, and a needless `setCategory` or re-pin can change the hardware format and stop it. Only the capture *start* re-pins when the live input isn't the wanted mic; in-place rebuilds don't. `DesktopAudioDevices.applyCaptureRoute` stays timeout-bounded on the Dart side.

### Soniox Translation & Reconnect
- Translation via Soniox `translation` config: `{"type": "one_way", "target_language": "<code>"}`.
- When target == source (e.g. Korean→Korean), transcription is copied into the translation panel.
- **Rotation timer:** WS is rotated every 10 minutes to prevent translation model degradation in long sessions; `contextText` (last 10 history lines) is replayed to keep continuity, **bounded to its last `maxContextChars` (3,000) characters**. Soniox refuses the whole config (400 `invalid_request`, "Context is too long") above 8,000 context tokens (measured: Chinese ≈1 token/char, Japanese 0.8, Korean 0.66) or about 19k characters, and the refused config used to be retried identically forever. A 400 also drops the context for the rest of that session.
- **Keepalive:** `{"type":"keepalive"}` after 5s without audio. Soniox closes a stream that gets neither audio nor a keepalive for 20s (408 `request_timeout`). Windows loopback delivers no packets while nothing plays, and a dead mic delivers nothing, so those gaps used to end in "A transcription error occurred" plus a reconnect that timed out again 20s later, on a loop.
- **Reconnect:** up to 50 attempts; audio buffered (capped at 30s) during reconnection. The retry counter resets only once a session proves healthy (a Soniox answer without an error, or 5s up without one), never on the WebSocket upgrade, which the proxy grants before it checks credentials. Soniox errors are healed quietly: the status bar shows "Reconnecting..." after 2s, one snackbar comes after 3 failed attempts in a row, and "Connection lost" when the 50 run out. Credentials are re-read on every connect (`credentials`), so a token refreshed mid-session is what the next rotation presents.
- **Diagnostics:** `SonioxRealtimeService.onDiagnostic` and the capture-failure handler report to `UserService.reportActivity` (`transcription_error`, `transcription_dropped`, `capture_failure`, ...), rate-limited per kind, with the proxy URL's token redacted. Read `activity_log` to see what actually happens in the field.
- **Optimistic start (ALL modes):** `_startRecording` and `_startConversationSession` do NOT await `connect()` — the mic starts and the UI flips to recording immediately (~200ms); the proxy handshake completes in the background while speech buffers (30s cap) and flushes only into a proven-live socket. `connect()` must be *invoked* before `_audioService.start()` (it synchronously clears the audio buffer before its first await). Start-time connection failures fall into the same reconnect/backoff path as a mid-session drop. Conversation stop first awaits the stored connect future (8s cap) so a fast stop-tap can't finalize a not-yet-open socket and drop the buffered speech.
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

### Account Sync (optional Google / Apple login)
- **Off by default and invisible without config** — with no OAuth client IDs in
  `AppConstants`/server env, the account sheet shows no sign-in buttons and
  every device stays standalone. Full setup: [docs/account-sync-setup.md](docs/account-sync-setup.md).
- **An account is itself a `users` row** (`acct_…`, no hardware id). Usage
  metering, proxy billing, purchases and cloud sessions all key off
  `users.user_id`, so a signed-in device just addresses a different row and
  every one of those paths works unchanged. `UserService.userId` resolves to the
  account when linked, the device otherwise; `deviceUserId` stays available
  because account endpoints authenticate as the *device* (the account may not
  exist yet at link time).
- **Time merges once per device, ledgered.** A device contributes
  `limit - FREE_BASE_MINUTES` purchased minutes plus its used seconds (clamped to
  the merged limit so a merge can exhaust but never indebt an account); the free
  30 is granted once per *account*, not per device. `account_members` records the
  contribution, so signing out and back in — or linking a different account —
  contributes zero and can never mint minutes. The device row drops back to the
  free tier at merge time, so purchased time exists in exactly one place.
- **Sign-out detaches this device only** (membership marked inactive, its
  account tokens deleted); it falls back to its own free-tier row and signing
  back in restores the shared balance.
- **Multi-token auth is required** — `users.auth_token_hash` is a single column,
  so two devices on one row would invalidate each other every re-registration,
  401-ping-ponging and dropping live WS proxy sessions. Tokens live in
  `auth_tokens`; `tokenMatchesUser()` also accepts the legacy column so older
  clients keep working.
- **Sync carries text + word timestamps + title, never audio** — raw PCM16 WAV is
  ~172 MB/hour against a 50 MB request cap. A synced session shows full text with
  no audio player on the device that didn't record it.
- **Sync stays off the UI isolate and off the bodies.** `syncFromServer` runs
  on every app resume, so it plans from `getSessionSyncIndex()` (created_at +
  title + updated_at only) and reads a full row only for a session it actually
  pushes; upload bodies are JSON+UTF-8 encoded and full-session downloads
  decoded via `compute()`. `planSessionSync`'s same-title branch uploads only
  when *this device* holds a real `updated_at` stamp (every edit/rename sets
  one); a pre-v6 row with no stamp has nothing to push — treating a missing
  server stamp as "local is newer" re-uploaded every legacy session's full
  body on the first sync after 1.1.2.
- Native sign-in on iOS/Android (`google_sign_in`, `sign_in_with_apple`);
  desktop has no native SDK and uses the server's browser OAuth broker
  (`/auth/google` → `/api/account/poll`). Apple's button is iOS/macOS only.
- `AccountService.stateListenable` pushes changes (the once-per-install restore
  probe can land seconds after launch); `MainScreen` listens and re-fetches usage
  + invalidates history, since both now address a different row.

### Theme (light/dark)
- `darkModeProvider` (`theme_provider.dart`) — toggle button in the main-screen header (sun/moon icon), persisted in SharedPreferences (`dark_mode`), **default light, independent of the OS setting**.
- Colors resolve through `AppConstants` static **getters** switched by `AppConstants.isDark` (set in `main()` and in `SilsiganApp.build` before the tree builds). `MainScreen` watches the provider so the whole subtree rebuilds on toggle; `SilsiganApp` swaps MaterialApp `ThemeData` (dialogs/popup menus) and the status-bar icon brightness.
- When adding UI: never mark a widget `const` if it references an `AppConstants` color (it would be canonicalized and skip theme rebuilds). The conversation top half keeps its teal identity in both themes; mic/save-active surfaces invert (pair `micButtonColor` with `micIconColor`, `saveButtonActiveColor` with `saveButtonActiveIconColor`).

### Auto-scroll (all streaming panels)
- Panel auto-follow goes through `_followTail` (line-by-line / transcript) / `_followNewest` (conversation, reversed lists): **skip when the gap is <1px** (most token updates don't change the extent — restarting a scroll activity ~10×/s for an hour was a measurable heat source), **`jumpTo` when the gap exceeds 2 viewports** (animating after a screen-off stint forces layout of every row flown past — a multi-second stall), animate the small in-between deltas as before. Preserve this shape when touching scroll code.

### Background Recording
- Android: `flutter_foreground_task` foreground service (`foregroundServiceType="microphone"` + wake lock, low-importance notification) keeps capture + WS alive while backgrounded.
- The plugin's service is sticky (survives — and its task-removal path resurrects it after — swipe-from-recents, while the Activity's FlutterEngine dies, so recording is dead anyway). `main()` calls `BackgroundService.reapZombieService()` to stop any leftover service at launch; `startRecordingService` awaits an in-flight reap so a fast mic tap can't race it.
- Windows / macOS: nothing suspends an unfocused desktop app, but idle sleep and App Nap did end hands-off sessions; `DesktopAudioDevices.setKeepAwake` now holds them off while capture runs (see Audio Recording → Desktop capture).
- iOS: `UIBackgroundModes: audio` (Info.plist) + MicCapture's live playAndRecord engine keep capture + WS alive while backgrounded — no foreground service. Force-quit still stops capture. An interruption (phone call, Siri) stops it until the interruption ends; MicCapture then rebuilds the engine, or the resume path restarts capture when the app comes back.
- App lifecycle: `paused` triggers autosave + sets `_wasPaused`; on `resumed` (if `_wasPaused`, filtering transient `inactive`), audio is restarted ONLY when capture actually died (`AudioService.isCapturingHealthy` — no recorder data in the last 2s). A session that survived the background stint is left untouched, so reopening causes no restart hitch or audio gap.

### Speaker capture on iPhone / iPad (ReplayKit)
The Mic / Speaker / Both selector ships on every platform. On iOS, "Speaker" is a system-wide ReplayKit broadcast. The Broadcast Upload Extension (`ios/ScreenAudio`, target `ScreenAudio`, App Group `group.com.silsigan.app`) converts `audioApp` buffers to 24 kHz mono PCM16. It writes them into an mmap'd ring (`ios/Runner/AudioRingBuffer.swift`, compiled into both targets), which the app drains every 100 ms through `readLoopback`.
- **ReplayKit app audio is big-endian signed 16-bit** (1–2 ch, ~44.1 kHz; the mic is little-endian). The first iOS version read it as little-endian, which turned every app into full-scale noise. That, not a ReplayKit limit, is why speaker mode "never worked" and was pulled in 1.1.1. The extension now builds `AVAudioFormat(streamDescription:)` from each buffer's own description, copies with `CMSampleBufferCopyPCMDataIntoAudioBufferList`, and converts with a streaming `AVAudioConverter` (downmix on), the same way LiveKit does. **Never hand-parse ReplayKit samples.**
- **Ring (header v2, magic `SILC`, 8 s):** strictly single-producer / single-consumer. The extension only moves `writePos`, the app only `readPos`, and a full ring drops new audio. `OSMemoryBarrier()` orders bytes against positions.
  - Stop, running, paused and the producer/consumer beats all live in the ring header, not App Group UserDefaults, which lagged 1–3 s between processes.
  - Beats use `CLOCK_MONOTONIC` ms, shared by both processes. A beat ahead of "now" predates a reboot and counts as stale.
  - The extension beats from a 100 ms timer, because samples stop entirely while nothing plays and the screen is static.
  - A paused broadcast (screen locked) stays "live" for up to 15 min, so a lock never reads as "ended". The allowance ends once the device is unlocked (`protectedDataDidBecomeAvailable` or the app becoming active), plus 10 s for ReplayKit to resume, so an extension that died while paused is still caught. One staleness threshold (5 s) serves both reuse and `BROADCAST_ENDED`.
  - The extension ends itself after 60 s with no reader. The app ends a broadcast it's reading on terminate (swipe-kill), and otherwise leaves a broadcast that's already live alone (it may be a Control Center start that `startLoopback` reuses).
- **Restarts never show the Start Broadcast sheet:**
  - `AudioService._doStart` knows a restart (`isRecording` on entry). `_teardown(restart: true)` then leaves the broadcast and ring alone, because a mic restart can outlast any stop grace.
  - `startLoopback(restart: true)` reuses the live broadcast, or returns `BROADCAST_ENDED` instead of presenting the picker.
  - `stopLoopback` still holds its stop for 1.5 s (the same as Android), and a following start cancels it.
  - Screen audio starts before the mic, so on a fresh start the mic only goes live after consent.
- **Picker:** a programmatic tap on `RPSystemBroadcastPickerView`'s button, with `preferredExtension` set and the mic button hidden. The keep-alive starts before the tap.
  - There are no callbacks, so `watchPicker` polls `presentedViewController`. A live ring counts as started even before the Darwin ping lands. A sheet seen and then gone for 8 s with no start fails as cancelled; otherwise the 90 s timeout applies.
  - A `stopped` never fails a pending start, since it may trail the previous broadcast.
  - A broadcast that comes up within 30 s of its start failing is stopped again, because its extension cleared our stop flag on start.
- **Broadcast ended under a session** (red pill tapped, extension killed): `readLoopback` returns `BROADCAST_ENDED` once (as does a restart). Speaker-only ends the session with a message, with the keep-alive held until `stopLoopback`. Both carries on with the mic, and `_speakerEndedThisSession` keeps in-session restarts on the mic until the next user-initiated start. In Both mode `isCapturingHealthy` judges the mic alone, so flowing screen audio can't hide a dead mic.
- **Speaker-only in the background:** no mic means nothing keeps the app alive, so a muted, looping, mixable `AVAudioPlayer` does it. It's restarted after interruptions.
- **Settings:** a one-time reset (`desktop_audio_ios_reset_v1`) cleared iOS source and mic picks saved in 1.0.15–1.0.17, since the selector was hidden from 1.1.1 to 1.1.4+78.
- **Limits:** apps that block screen recording (DRM video, some music) hand over silence. App audio already playing when the broadcast starts may not come through until playback restarts. Our own TTS is captured too. After 20 s of pure silence, a one-time hint says so (the flag is per session, so a restart doesn't reset it).

### Purchases
- RevenueCat package identifiers: `hours_1`, `hours_5`, `hours_10`, `hours_30`, `hours_50` (60, 300, 600, 1800, 3000 minutes respectively).
- iOS only — Android shows mock UI with "not available" snackbar.
- Successful purchase → POST to Render to credit minutes → refresh `_usedSeconds` / `_limitMinutes`.
- Pending purchases (Apple credited but server failed) are persisted and retried on next launch.
- **Restore Purchases** is a quiet footer link next to Privacy Policy / Terms of Use. It re-credits pending store charges and refreshes the server ledger. **Never call `Purchases.restorePurchases()`.** Hour packs are consumables: StoreKit restore prompts for the Apple ID and returns nothing, and App Review rejected exactly that under guideline 3.1.1 (2026-09). Minutes already survive reinstall via the hardware-ID / account ledger.
- **Contact Support** sits in the old Restore position on the same sheet. Tapping it closes the sheet and opens the 1:1 support chat, so Back from the chat returns to the main screen.

### Support chat
- One continuous thread per identity (`UserService.userId` — account row when signed in, device otherwise). Sending the first message creates it; there is no bot and no second thread.
- `users.service_admin` (boolean, default false) marks team members. Set by hand: `UPDATE users SET service_admin = TRUE WHERE friend_code = '…';`. A signed-in account inherits the flag from an active member device. Team members land in an inbox of every thread and can reply as the team; customers only ever see their own.
- REST in `server/support-chat.js` (`/api/support/status|thread|send|threads|push-token`), authenticated the same way as every other POST. The client polls every 3s while a thread is open.
- Push is optional FCM (HTTP v1 via `FIREBASE_SERVICE_ACCOUNT` on Render + `flutterfire configure` on the client). Without it, chat still works. Full setup: [docs/support-chat-setup.md](docs/support-chat-setup.md).
- A customer message notifies every admin device; a team reply notifies that customer. The OS permission prompt is deferred until the first sent message (customers) or opening the inbox (team).

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
- **No extra tab bar** — main screen + modal sheets; support chat is the one pushed page.

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
