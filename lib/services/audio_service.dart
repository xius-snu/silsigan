import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:record/record.dart' as rec;
import 'package:path_provider/path_provider.dart';
import '../providers/desktop_audio_source_provider.dart';
import '../utils/constants.dart';
import '../utils/pcm_mixer.dart';
import 'desktop_audio_devices.dart';

/// Calm copy when the user cancels or denies the screen-audio picker
/// (MediaProjection / ReplayKit). Never dump PlatformException text.
const kScreenAudioDeniedMessage =
    "Screen audio wasn't started. You can try again, or switch to Mic.";

bool isScreenAudioDenied(Object e) {
  final code = e is PlatformException ? e.code : '';
  final message = e is PlatformException ? (e.message ?? '') : e.toString();
  final details = e is PlatformException ? '${e.details ?? ''}' : '';
  final blob = '$code $message $details'.toLowerCase();
  final cancelish = blob.contains('permission') ||
      blob.contains('not granted') ||
      blob.contains('cancel') ||
      blob.contains('result_canceled') ||
      blob.contains('denied');
  if (!cancelish) return false;
  return blob.contains('screen') ||
      blob.contains('capture') ||
      blob.contains('broadcast') ||
      blob.contains('projection') ||
      code.toUpperCase() == 'CANCELLED' ||
      code.toUpperCase() == 'DENIED';
}

String recordingStartErrorMessage(Object e) {
  if (isScreenAudioDenied(e)) return kScreenAudioDeniedMessage;
  // iOS MicCapture: a call or another recorder holds the mic, or there is no
  // usable input route at all.
  if (e is PlatformException && e.code == 'MIC_BUSY') {
    return 'Another app is using the microphone. Try again when it is free.';
  }
  if (e is PlatformException && e.code == 'MIC_UNAVAILABLE') {
    return 'No microphone is available right now.';
  }
  return "Couldn't start recording. You can try again.";
}

/// Snackbar copy when a live session had to end because capture could not
/// be kept alive. [e] is the restart failure, if there was one.
String captureLostMessage(Object? e) {
  if (e != null && isScreenAudioDenied(e)) return kScreenAudioDeniedMessage;
  if (e is PlatformException && e.code == 'MIC_BUSY') {
    return 'Another app is using the microphone — recording stopped.';
  }
  return 'Microphone error — recording stopped';
}

String _captureErrorText(Object e) {
  if (isScreenAudioDenied(e)) return kScreenAudioDeniedMessage;
  if (e is PlatformException) return 'Capture error';
  return e.toString();
}

class AudioService {
  // iOS / iPadOS: our own AVAudioEngine capture (ios/Runner/MicCapture.swift).
  // flutter_sound's iOS stream recorder failed silently and left sessions on
  // Stop with no audio (seen on iPad). It ignored engine-start errors and
  // reported success, built its converter from a pre-start format snapshot,
  // and never handled configuration changes or interruptions. MicCapture
  // heals those in place, throws start failures, and reports MIC_LOST when
  // it runs out of retries. [_checkIosStall] backs all of that up from Dart.
  static const _iosMic = MethodChannel('com.silsigan.app/mic_capture');
  static const _iosMicPcm = EventChannel('com.silsigan.app/mic_capture/pcm');
  StreamSubscription<dynamic>? _iosMicSub;
  // MicCapture gave up healing in place. Capture is gone until the next start.
  bool _iosMicLost = false;
  // A call / Siri / alarm holds the session. MicCapture resumes on its own
  // when the interruption ends; a restart before that would only fail.
  DateTime? _iosInterruptedSince;
  Timer? _iosStallTimer;
  bool _iosStallReported = false;
  // Start of the current "waiting for audio" window: the capture start, the
  // last buffer, the end of an interruption, or the app coming back.
  DateTime? _iosLastSignalAt;
  DateTime? _iosLastTickAt;

  /// Longer than MicCapture's own recovery (2s stall detection, then a
  /// rebuild), so a heal already under way is not cut short by a restart.
  static const _iosStallTimeout = Duration(seconds: 6);

  /// iOS doesn't promise an .ended for every interruption. Past this, a
  /// silent "interrupted" capture is treated as stalled like any other.
  static const _iosMaxInterruption = Duration(minutes: 10);

  /// Bound on MicCapture's start, which reconfigures the audio session and
  /// starts the engine on the platform main thread. A wedged session must
  /// fail the start, not leave the button stuck on "starting".
  static const _iosStartTimeout = Duration(seconds: 6);

  // record package (Android + desktop). Android deliberately does NOT use
  // flutter_sound: its streaming engine polls AudioRecord on the Android
  // platform main thread via a runnable that re-posts itself once per read —
  // the queued-runnable population grows without bound over a long session,
  // saturating the main looper (heat, then a hard UI freeze after ~30-60min
  // that even survives swipe-away because the mic foreground service keeps
  // the process alive). The record package reads on a dedicated thread.
  rec.AudioRecorder? _streamRecorder;
  StreamSubscription? _streamSubscription;
  StreamSubscription? _stateErrorSub;

  // Linux "both": a second record instance on the sink monitor. Windows /
  // macOS / Android / iOS speaker capture goes through native loopback.
  rec.AudioRecorder? _loopbackRecorder;
  StreamSubscription? _loopbackSubscription;

  DesktopAudioSettings? _desktop;
  final BytesBuilder _speakerPending = BytesBuilder(copy: false);
  bool _chunkBusy = false;

  // The iOS broadcast ended under this capture (BROADCAST_ENDED): stop
  // polling a ring nobody fills. Reset on every start.
  bool _loopbackEnded = false;
  // Whether any non-silent speaker audio has arrived since the capture
  // started. Apps that block screen recording hand over silence.
  bool _speakerAudioHeard = false;

  /// Native capture failure after start. record (Android / desktop) reports
  /// these asynchronously on its state stream; on iOS they come from
  /// MicCapture's MIC_LOST or from [_checkIosStall]. Unobserved, a failure
  /// would look like a silent recording that never produces audio.
  Function(String error)? onCaptureError;

  /// The iOS screen broadcast ended while this capture still read it (the
  /// red status-bar pill was tapped, or iOS killed the extension). Speaker
  /// audio is over; the mic, if any, keeps going.
  void Function()? onLoopbackEnded;

  /// Speaker capture is on and nothing audible has come through it yet.
  /// Used to explain an empty transcript when the playing app blocks screen
  /// recording.
  bool get speakerStillSilent =>
      isRecording && _wantSpeaker && !_loopbackEnded && !_speakerAudioHeard;

  Timer? _chunkTimer;
  // Audio captured since the last chunk tick. BytesBuilder(copy: false) keeps
  // the incoming Uint8List references and concatenates once per tick — no
  // per-byte copying into a growable List<int>.
  final BytesBuilder _pending = BytesBuilder(copy: false);
  bool _isInitialized = false;

  // When the recorder last delivered data — used by [isCapturingHealthy].
  DateTime? _lastDataAt;
  // Same, microphone only. In Both mode screen audio keeps arriving while a
  // dead mic doesn't, and must not vouch for it.
  DateTime? _lastMicDataAt;

  // Disk-based recording instead of in-memory list
  RandomAccessFile? _tempRaf;
  String? _tempFilePath;
  int _pcmBytesWritten = 0;

  Function(Uint8List)? onAudioChunk;

  bool get _useRecord => !Platform.isIOS;

  Future<void> init() async {
    if (_isInitialized) return;
    if (_useRecord) {
      _streamRecorder = rec.AudioRecorder();
    }
    _isInitialized = true;
  }

  bool get isRecording => _chunkTimer != null;

  /// Whether capture is running AND the recorder delivered data recently.
  /// Used on app-resume to decide if the recorder survived the background
  /// stint (Android, where the foreground service keeps it alive) or must be
  /// restarted (iOS suspension kills audio; some Android OEMs do too). When
  /// the mic is wanted it's the mic that must be alive: in Both mode, screen
  /// audio flowing would otherwise hide a dead microphone for good.
  bool get isCapturingHealthy {
    if (!isRecording) return false;
    final last = _wantMic ? _lastMicDataAt : _lastDataAt;
    return last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 2);
  }

  // In-flight start() — concurrent callers (e.g. two lifecycle resumes while
  // a restart is stuck behind a slow native call) share one future instead of
  // double-starting, which would orphan a chunk timer + subscriptions forever.
  Future<void>? _starting;

  // Bumped synchronously by every stop(). start() snapshots it before its
  // first await and aborts at each later checkpoint if a stop intervened —
  // otherwise an abandoned start (e.g. the resume-path restart racing a Stop
  // tap) could bring capture live AFTER the stop completed, leaving the mic
  // hot on an orphaned recorder and appending post-stop audio to the WAV.
  int _stopGen = 0;

  bool get _wantMic => _desktop == null || _desktop!.captureMic;
  bool get _wantSpeaker => _desktop != null && _desktop!.captureSpeaker;

  Future<void> start({DesktopAudioSettings? desktop}) {
    // Snapshot before any await so a stop() racing this start cannot see a
    // half-applied config. Callers pass Mic/Speaker/Both settings on every
    // platform that shows the selector; omitted means microphone-only.
    _desktop = desktop ?? const DesktopAudioSettings();
    // Single-flight: a second start while one is in flight would skip the
    // isRecording guard in _doStart (the chunk timer isn't armed yet) and
    // leak the first timer/subscription when both complete.
    return _starting ??= _doStart().whenComplete(() => _starting = null);
  }

  Future<void> _doStart() async {
    // Snapshot before any await: a stop() entering after this point bumps
    // the generation synchronously, so every checkpoint below sees it.
    final gen = _stopGen;

    // A capture is live, so this start replaces it in the middle of a session
    // (resume, capture recovery) rather than beginning one.
    final restart = isRecording;

    // Stop any existing capture first. Raw teardown, not stop() — stop()
    // bumps the abort generation and awaits _starting, i.e. ourselves.
    if (restart) await _teardown(restart: true);
    if (!_isInitialized) await init();
    _pending.clear();
    _speakerPending.clear();
    // Health is judged on data from THIS capture only. A stale timestamp
    // from before a restart must not vouch for a recorder that hasn't
    // delivered anything yet.
    _lastDataAt = null;
    _lastMicDataAt = null;
    if (!restart) {
      // Per session, not per capture: a resume restart mustn't forget that
      // screen audio was already heard.
      _loopbackEnded = false;
      _speakerAudioHeard = false;
    }

    // Close any lingering file handle before (re)opening
    try {
      _tempRaf?.closeSync();
    } catch (_) {}
    _tempRaf = null;

    // Open temp file for PCM recording on disk (append if resuming same session)
    if (_tempFilePath != null && await File(_tempFilePath!).exists()) {
      _tempRaf = await File(_tempFilePath!).open(mode: FileMode.append);
    } else {
      final tempDir = await getTemporaryDirectory();
      _tempFilePath =
          '${tempDir.path}/silsigan_recording_${DateTime.now().millisecondsSinceEpoch}.pcm';
      _tempRaf = await File(_tempFilePath!).open(mode: FileMode.write);
      _pcmBytesWritten = 0;
    }
    // A stop() arrived while the file was opening: the session is over.
    // Leave the post-stop state (raf open for a potential save) untouched.
    if (gen != _stopGen) return;

    try {
      if (_useRecord) {
        await _startNativeCapture(gen);
      } else {
        await _startIosCapture(gen, restart: restart);
      }
    } catch (e) {
      // Mic or loopback may already be live — release them so a failed
      // speaker device cannot leave the default mic open.
      await _teardown();
      rethrow;
    }
    if (gen != _stopGen) return;

    _chunkTimer?.cancel();
    _chunkTimer = Timer.periodic(
      const Duration(milliseconds: AppConstants.chunkIntervalMs),
      (_) => _sendChunk(),
    );
    if (!_useRecord && _wantMic) _startIosStallWatch();
  }

  Future<void> _startIosCapture(int gen, {required bool restart}) async {
    // Screen audio first. On a restart it's an instant reuse of the running
    // broadcast; on a fresh start the mic then goes live only once the user
    // has started the broadcast, not for the whole time the sheet is up.
    if (_wantSpeaker && DesktopAudioDevices.nativeLoopbackSupported) {
      try {
        await DesktopAudioDevices.startLoopback(
          deviceId: _desktop?.speakerDeviceId,
          restart: restart,
        );
        _loopbackEnded = false;
      } on PlatformException catch (e) {
        // Only a restart gets this: the broadcast died while the capture was
        // being replaced. Same outcome as the chunk loop finding it: the
        // session ends (speaker only) or carries on with the mic (Both).
        if (e.code != 'BROADCAST_ENDED') rethrow;
        if (!_loopbackEnded) {
          _loopbackEnded = true;
          onLoopbackEnded?.call();
        }
      }
      if (gen != _stopGen) {
        await DesktopAudioDevices.stopLoopback();
        return;
      }
    }
    if (_wantMic) {
      final micId = _desktop?.micDeviceId;
      final bluetoothMic = await _isBluetoothMic(micId);
      if (gen != _stopGen) return;
      // Cancel before listening: a cancel nulls the channel's handler, so a
      // late one would silence the new subscription.
      _cancelIosMicStream();
      _iosMicLost = false;
      _iosInterruptedSince = null;
      _iosMicSub = _iosMicPcm.receiveBroadcastStream().listen(
        (dynamic data) {
          if (data is Map) {
            // {"interrupted": bool} status from MicCapture.
            final interrupted = data['interrupted'] == true;
            if (!interrupted) {
              _iosInterruptedSince = null;
              // MicCapture rebuilds now. Give it a fresh window.
              _iosLastSignalAt = DateTime.now();
            } else {
              _iosInterruptedSince ??= DateTime.now();
            }
            return;
          }
          if (data is! Uint8List || data.isEmpty) return;
          _lastDataAt = DateTime.now();
          _lastMicDataAt = _lastDataAt;
          _iosLastSignalAt = _lastDataAt;
          _iosStallReported = false;
          _pending.add(data);
        },
        // MIC_LOST: MicCapture already retried in place. The stall check
        // turns it into a restart (foreground only).
        onError: (Object _) {
          _iosMicLost = true;
        },
      );
      // One native pass: session category + activation, mic pin, engine
      // start. A failure anywhere in it throws here, so a dead mic can never
      // be reported as started.
      await _iosMic.invokeMethod<void>('start', {
        'sampleRate': AppConstants.sampleRate,
        'channels': AppConstants.numChannels,
        'micDeviceId': micId ?? '',
        'bluetoothMic': bluetoothMic,
      }).timeout(_iosStartTimeout);
      if (gen != _stopGen) {
        // A stop() intervened while the native start was in flight.
        await _stopIosMic();
        return;
      }
    }
  }

  Future<void> _startNativeCapture(int gen) async {
    if (_wantMic) {
      await _startWithRecord(gen, deviceId: _desktop?.micDeviceId);
      if (gen != _stopGen) return;
    } else if (_wantSpeaker && !DesktopAudioDevices.nativeLoopbackSupported) {
      // Linux speaker-only: the monitor source is just another capture
      // device as far as `record` is concerned.
      await _startWithRecord(
        gen,
        deviceId: await _resolvedSpeakerDeviceId(),
      );
      if (gen != _stopGen) return;
    }

    if (_wantSpeaker && DesktopAudioDevices.nativeLoopbackSupported) {
      await DesktopAudioDevices.startLoopback(
        deviceId: _desktop?.speakerDeviceId,
      );
      if (gen != _stopGen) {
        await DesktopAudioDevices.stopLoopback();
      }
    } else if (_wantMic &&
        _wantSpeaker &&
        !DesktopAudioDevices.nativeLoopbackSupported) {
      await _startLinuxMonitor(gen, await _resolvedSpeakerDeviceId());
    }
  }

  Future<String?> _resolvedSpeakerDeviceId() async {
    final id = _desktop?.speakerDeviceId;
    if (id != null && id.isNotEmpty) return id;
    final outputs = await DesktopAudioDevices.listOutputs();
    if (outputs.isEmpty) {
      throw Exception(
        'No speaker device found. Pick a speaker in the audio source menu.',
      );
    }
    return outputs.first.id;
  }

  Future<void> _startLinuxMonitor(int gen, String? deviceId) async {
    _loopbackRecorder = rec.AudioRecorder();
    final recorder = _loopbackRecorder!;
    final rec.InputDevice? device = (deviceId != null && deviceId.isNotEmpty)
        ? rec.InputDevice(id: deviceId, label: deviceId)
        : null;
    final stream = await recorder.startStream(
      rec.RecordConfig(
        encoder: rec.AudioEncoder.pcm16bits,
        sampleRate: AppConstants.sampleRate,
        numChannels: AppConstants.numChannels,
        device: device,
      ),
    );
    if (gen != _stopGen) {
      unawaited(recorder.stop().catchError((_) => null));
      return;
    }
    _loopbackSubscription = stream.listen((data) {
      _lastDataAt = DateTime.now();
      _speakerPending.add(data);
    });
  }

  Future<void> _startWithRecord(int gen, {String? deviceId}) async {
    // Pin the instance being started: a concurrent stop()'s timeout path can
    // swap _streamRecorder mid-flight, and the abort below must release the
    // recorder that actually went live.
    final recorder = _streamRecorder!;
    final inputs = (Platform.isAndroid)
        ? await DesktopAudioDevices.listInputs()
        : const <DesktopAudioDevice>[];
    if (gen != _stopGen) return;
    final bluetoothMic = DesktopAudioDevices.isBluetoothInput(deviceId, inputs);
    final resolvedId = bluetoothMic
        ? deviceId
        : DesktopAudioDevices.resolvedInputId(deviceId, inputs);
    await DesktopAudioDevices.applyCaptureRoute(
      micDeviceId: deviceId,
      bluetoothMic: bluetoothMic,
      updateMic: true,
    );
    if (gen != _stopGen) return;
    final rec.InputDevice? device =
        (resolvedId != null && resolvedId.isNotEmpty)
            ? rec.InputDevice(id: resolvedId, label: resolvedId)
            : null;
    final stream = await recorder.startStream(
      rec.RecordConfig(
        encoder: rec.AudioEncoder.pcm16bits,
        sampleRate: AppConstants.sampleRate,
        numChannels: AppConstants.numChannels,
        device: device,
        // Default is the phone mic + A2DP headphones: do not start a
        // Bluetooth SCO link unless the user picked a BT headset mic.
        // SCO would silently switch capture to the low-bandwidth headset
        // mic and keep TTS on the same HFP route.
        androidConfig: rec.AndroidRecordConfig(
          manageBluetooth: bluetoothMic,
          audioSource: bluetoothMic || (deviceId != null && deviceId.isNotEmpty)
              ? rec.AndroidAudioSource.defaultSource
              : rec.AndroidAudioSource.mic,
          speakerphone: false,
          audioManagerMode: rec.AudioManagerMode.modeNormal,
        ),
      ),
    );
    if (gen != _stopGen) {
      // A stop() intervened while the native start was in flight — release
      // the mic instead of wiring up capture for a session that's over.
      unawaited(recorder.stop().catchError((_) => null));
      return;
    }
    _streamSubscription = stream.listen((data) {
      _lastDataAt = DateTime.now();
      _lastMicDataAt = _lastDataAt;
      _pending.add(data);
    });
    _stateErrorSub = recorder.onStateChanged().listen(
          (_) {},
          onError: (Object e) => onCaptureError?.call(_captureErrorText(e)),
        );
    await DesktopAudioDevices.applyCaptureRoute(
      micDeviceId: deviceId,
      bluetoothMic: bluetoothMic,
      updateMic: true,
    );
  }

  Future<bool> _isBluetoothMic(String? deviceId) async {
    if (deviceId == null || deviceId.isEmpty) return false;
    if (!(Platform.isIOS || Platform.isAndroid)) return false;
    final inputs = await DesktopAudioDevices.listInputs();
    return DesktopAudioDevices.isBluetoothInput(deviceId, inputs);
  }

  Future<void> _stopIosMic() async {
    try {
      await _iosMic
          .invokeMethod<void>('stop')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    _cancelIosMicStream();
  }

  void _cancelIosMicStream() {
    final sub = _iosMicSub;
    _iosMicSub = null;
    // cancel() detaches the channel handler synchronously. The platform's ack
    // isn't worth holding a stop, or the restart behind it, for.
    if (sub != null) unawaited(sub.cancel());
  }

  void _startIosStallWatch() {
    _iosStallTimer?.cancel();
    _iosStallReported = false;
    _iosLastSignalAt = DateTime.now();
    _iosLastTickAt = null;
    _iosStallTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkIosStall(),
    );
  }

  /// Last line of defense on iOS: capture that delivers nothing, or that
  /// MicCapture gave up on, goes to [onCaptureError], which restarts it or
  /// ends the session with a message. The UI never keeps claiming to record
  /// silence. Foreground only: iOS won't let a backgrounded app start
  /// recording, so a restart from there would just end the session. The
  /// lifecycle resume path restarts dead capture when the app comes back.
  void _checkIosStall() {
    if (!isRecording || _iosStallReported) return;
    final now = DateTime.now();
    final previousTick = _iosLastTickAt;
    _iosLastTickAt = now;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final suspended = previousTick != null &&
        now.difference(previousTick) > const Duration(seconds: 3);
    if (suspended ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      // Backgrounded, or the isolate was just thawed. The resume path
      // restarts dead capture first; judge afresh after it's had a window,
      // instead of racing it for one of the two restarts a minute.
      _iosLastSignalAt = now;
      return;
    }
    // A call answered from the banner keeps the app in the foreground. The
    // mic is the call's until it ends and MicCapture resumes by itself, so a
    // restart now would only fail and end the session.
    final interruptedSince = _iosInterruptedSince;
    if (!_iosMicLost &&
        interruptedSince != null &&
        now.difference(interruptedSince) < _iosMaxInterruption) {
      return;
    }
    final last = _iosLastSignalAt;
    final stalled =
        _iosMicLost || last == null || now.difference(last) > _iosStallTimeout;
    if (!stalled) return;
    _iosStallReported = true;
    onCaptureError?.call('Microphone stopped delivering audio');
  }

  void _writeToDisk(List<int> data) {
    try {
      _tempRaf?.writeFromSync(data);
      _pcmBytesWritten += data.length;
    } catch (_) {
      // Disk write failed — don't crash recording
    }
  }

  void _sendChunk() {
    if (_wantSpeaker &&
        DesktopAudioDevices.nativeLoopbackSupported &&
        !_loopbackEnded) {
      if (_chunkBusy) return;
      _chunkBusy = true;
      unawaited(_sendChunkAsync().whenComplete(() => _chunkBusy = false));
      return;
    }
    _flushPending();
  }

  Future<void> _sendChunkAsync() async {
    try {
      final extra = await DesktopAudioDevices.readLoopback();
      if (extra.isNotEmpty) {
        _lastDataAt = DateTime.now();
        if (!_speakerAudioHeard && _hasSound(extra)) _speakerAudioHeard = true;
        _speakerPending.add(extra);
      }
    } on PlatformException catch (e) {
      if (e.code == 'BROADCAST_ENDED') {
        // Not a capture fault to restart through: the user ended the
        // broadcast (or iOS did). Restarting would put the Start Broadcast
        // sheet straight back up.
        if (!_loopbackEnded) {
          _loopbackEnded = true;
          onLoopbackEnded?.call();
        }
      } else {
        onCaptureError?.call(_captureErrorText(e));
      }
    } catch (e) {
      onCaptureError?.call(_captureErrorText(e));
    }
    _flushPending();
  }

  /// Anything above -60 dBFS. A playing app that blocks screen recording
  /// hands over exact silence; real content, even quiet, clears this.
  static bool _hasSound(Uint8List pcm16) {
    for (int i = 0; i + 1 < pcm16.length; i += 2) {
      final u = pcm16[i] | (pcm16[i + 1] << 8);
      final s = u >= 0x8000 ? u - 0x10000 : u;
      if (s > 32 || s < -32) return true;
    }
    return false;
  }

  void _flushPending() {
    final Uint8List bytes;
    if (_wantMic && _wantSpeaker) {
      if (_pending.isEmpty && _speakerPending.isEmpty) return;
      bytes = mixPcm16Le(_pending.takeBytes(), _speakerPending.takeBytes());
    } else if (_wantSpeaker &&
        !_wantMic &&
        DesktopAudioDevices.nativeLoopbackSupported) {
      if (_speakerPending.isEmpty) return;
      bytes = _speakerPending.takeBytes();
    } else {
      if (_pending.isEmpty) return;
      bytes = _pending.takeBytes();
    }
    if (bytes.isEmpty) return;
    // One disk write per tick instead of one per recorder callback — the
    // recorder delivers many small buffers per second and each writeFromSync
    // was a blocking syscall on the UI isolate.
    _writeToDisk(bytes);
    onAudioChunk?.call(bytes);
  }

  Future<void> stop() async {
    // Signal any in-flight start to abort at its next checkpoint, then wait
    // for it to settle (bounded — a wedged native start must not hang the
    // stop path) so teardown runs against a settled recorder state.
    _stopGen++;
    final starting = _starting;
    if (starting != null) {
      try {
        await starting.timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    await _teardown();
  }

  /// [restart]: the capture is being replaced mid-session. On iOS the screen
  /// broadcast and its ring are then left alone (when the new settings still
  /// want them) for the next start to claim. A mic restart can outlast the
  /// native stop grace, and a stopped broadcast can only come back through
  /// the Start Broadcast sheet.
  Future<void> _teardown({bool restart = false}) async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    _iosStallTimer?.cancel();
    _iosStallTimer = null;

    _loopbackSubscription?.cancel();
    _loopbackSubscription = null;
    final loopbackRecorder = _loopbackRecorder;
    _loopbackRecorder = null;
    if (loopbackRecorder != null) {
      try {
        await loopbackRecorder.stop().timeout(const Duration(seconds: 2));
      } catch (_) {}
      unawaited(loopbackRecorder.dispose().catchError((_) {}));
    }
    final keepBroadcast =
        restart && Platform.isIOS && _wantSpeaker && !_loopbackEnded;
    if (DesktopAudioDevices.nativeLoopbackSupported && !keepBroadcast) {
      try {
        final extra = await DesktopAudioDevices.readLoopback();
        if (extra.isNotEmpty) {
          _speakerPending.add(extra);
        }
      } catch (_) {}
      await DesktopAudioDevices.stopLoopback();
    }

    if (_useRecord) {
      _streamSubscription?.cancel();
      _streamSubscription = null;
      _stateErrorSub?.cancel();
      _stateErrorSub = null;
      final recorder = _streamRecorder;
      if (recorder != null) {
        // Skip the native stop when capture already ended on its own —
        // record_android never answers stop() once its record thread has
        // exited, so an unconditional stop would burn the full 3s timeout
        // below (stop button stuck in processing) and needlessly discard
        // the instance.
        bool live = true;
        try {
          live =
              await recorder.isRecording().timeout(const Duration(seconds: 1));
        } catch (_) {}
        if (live) {
          try {
            // A recorder whose native thread died never answers stop(), and
            // the package serializes calls per instance — an unanswered stop
            // would wedge every later start on this instance's wait queue.
            // Bound the wait and replace the instance so one native failure
            // can't brick recording until app restart.
            await recorder.stop().timeout(const Duration(seconds: 3));
          } catch (_) {
            _streamRecorder = rec.AudioRecorder();
            // Best-effort: if the native call was merely slow (not dead),
            // this queues behind it and releases the mic + event channels
            // once it answers; against a truly wedged instance it stays
            // pending forever, which is harmless.
            unawaited(recorder.dispose().catchError((_) {}));
          }
        }
      }
    } else {
      await _stopIosMic();
    }

    // Write the tail captured since the last chunk tick so the saved WAV
    // doesn't lose the final ≤100ms.
    if (_wantMic && _wantSpeaker) {
      if (_pending.isNotEmpty || _speakerPending.isNotEmpty) {
        _writeToDisk(
          mixPcm16Le(_pending.takeBytes(), _speakerPending.takeBytes()),
        );
      }
    } else if (_wantSpeaker &&
        !_wantMic &&
        DesktopAudioDevices.nativeLoopbackSupported) {
      if (_speakerPending.isNotEmpty) {
        _writeToDisk(_speakerPending.takeBytes());
      }
    } else if (_pending.isNotEmpty) {
      _writeToDisk(_pending.takeBytes());
    }
    _speakerPending.clear();

    // Flush and keep temp file open for potential save
    try {
      await _tempRaf?.flush();
    } catch (_) {}
  }

  Future<String> saveRecordingAsWav(String fileName) async {
    // Close the temp PCM file
    try {
      await _tempRaf?.flush();
      await _tempRaf?.close();
    } catch (_) {}
    _tempRaf = null;

    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/$fileName';

    // Stream copy: write WAV header then copy PCM data in chunks
    final outRaf = await File(filePath).open(mode: FileMode.write);

    // Placeholder, rewritten below from the bytes actually copied. A header
    // whose data-size doesn't match the payload is rejected by desktop players.
    await outRaf.writeFrom(_buildWavHeader(0));

    // Copy PCM data from temp file in chunks (avoids loading entire file)
    var copied = 0;
    if (_tempFilePath != null && await File(_tempFilePath!).exists()) {
      final inStream = File(_tempFilePath!).openRead();
      await for (final chunk in inStream) {
        await outRaf.writeFrom(chunk);
        copied += chunk.length;
      }
      // Clean up temp file
      try {
        await File(_tempFilePath!).delete();
      } catch (_) {}
    }
    // PCM16 frames are 2 bytes. An odd tail makes the WAV invalid.
    if (copied.isOdd) {
      await outRaf.writeFrom(const [0]);
      copied += 1;
    }
    await outRaf.setPosition(0);
    await outRaf.writeFrom(_buildWavHeader(copied));

    await outRaf.close();
    _tempFilePath = null;
    _pcmBytesWritten = 0;

    return filePath;
  }

  void clearRecording() {
    // Close and delete temp file
    try {
      _tempRaf?.closeSync();
    } catch (_) {}
    _tempRaf = null;

    if (_tempFilePath != null) {
      try {
        File(_tempFilePath!).deleteSync();
      } catch (_) {}
      _tempFilePath = null;
    }
    _pcmBytesWritten = 0;
  }

  bool get hasRecording => _pcmBytesWritten > 0;

  /// After a crash mid-recording the in-memory temp-file pointer is lost, but
  /// the PCM the recorder streamed to disk survives. Find the most recent
  /// orphaned chunk and adopt it so a subsequent [saveRecordingAsWav] includes
  /// the recovered audio. Returns true if an orphan was adopted. Only acts when
  /// idle (no active recording and no temp file already known).
  Future<bool> adoptOrphanRecording() async {
    if (isRecording || _tempFilePath != null || _pcmBytesWritten > 0) {
      return false;
    }
    try {
      final orphans = await _listOrphanPcmFiles();
      if (orphans.isEmpty) return false;
      // Newest first by modified time.
      orphans.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      final newest = orphans.first;
      final len = await newest.length();
      if (len <= 0) {
        try {
          newest.deleteSync();
        } catch (_) {}
        return false;
      }
      _tempFilePath = newest.path;
      _pcmBytesWritten = len;
      // Drop older orphans so they don't accumulate.
      for (final f in orphans.skip(1)) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Delete orphaned PCM chunks from a previous crash without adopting them —
  /// used when there is no draft to attach them to.
  Future<void> clearOrphanRecordings() async {
    if (isRecording || _tempFilePath != null) return;
    try {
      for (final f in await _listOrphanPcmFiles()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<List<File>> _listOrphanPcmFiles() async {
    final tempDir = await getTemporaryDirectory();
    return tempDir.listSync().whereType<File>().where((f) {
      final name = f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : '';
      return name.startsWith('silsigan_recording_') && name.endsWith('.pcm');
    }).toList();
  }

  Uint8List _buildWavHeader(int pcmDataSize) {
    const sampleRate = AppConstants.sampleRate;
    const numChannels = AppConstants.numChannels;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final fileSize = 36 + pcmDataSize;

    final buffer = ByteData(44);
    int offset = 0;

    // RIFF header
    buffer.setUint8(offset++, 0x52); // R
    buffer.setUint8(offset++, 0x49); // I
    buffer.setUint8(offset++, 0x46); // F
    buffer.setUint8(offset++, 0x46); // F
    buffer.setUint32(offset, fileSize, Endian.little);
    offset += 4;
    buffer.setUint8(offset++, 0x57); // W
    buffer.setUint8(offset++, 0x41); // A
    buffer.setUint8(offset++, 0x56); // V
    buffer.setUint8(offset++, 0x45); // E

    // fmt chunk
    buffer.setUint8(offset++, 0x66); // f
    buffer.setUint8(offset++, 0x6D); // m
    buffer.setUint8(offset++, 0x74); // t
    buffer.setUint8(offset++, 0x20); // (space)
    buffer.setUint32(offset, 16, Endian.little);
    offset += 4;
    buffer.setUint16(offset, 1, Endian.little);
    offset += 2;
    buffer.setUint16(offset, numChannels, Endian.little);
    offset += 2;
    buffer.setUint32(offset, sampleRate, Endian.little);
    offset += 4;
    buffer.setUint32(offset, byteRate, Endian.little);
    offset += 4;
    buffer.setUint16(offset, blockAlign, Endian.little);
    offset += 2;
    buffer.setUint16(offset, bitsPerSample, Endian.little);
    offset += 2;

    // data chunk
    buffer.setUint8(offset++, 0x64); // d
    buffer.setUint8(offset++, 0x61); // a
    buffer.setUint8(offset++, 0x74); // t
    buffer.setUint8(offset++, 0x61); // a
    buffer.setUint32(offset, pcmDataSize, Endian.little);

    return Uint8List.sublistView(buffer, 0, buffer.lengthInBytes);
  }

  Future<void> dispose() async {
    await stop();
    clearRecording();
    if (_isInitialized) {
      if (_useRecord) {
        await _streamRecorder?.dispose();
        _streamRecorder = null;
      }
      _isInitialized = false;
    }
  }
}
