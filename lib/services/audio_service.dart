import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
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
  if (e is PlatformException) {
    return "Couldn't start recording. You can try again.";
  }
  return 'Failed to start: $e';
}

String _captureErrorText(Object e) {
  if (isScreenAudioDenied(e)) return kScreenAudioDeniedMessage;
  if (e is PlatformException) return 'Capture error';
  return e.toString();
}

class AudioService {
  // flutter_sound (iOS only — its openRecorder also configures the
  // playAndRecord audio session that TTS playback depends on)
  FlutterSoundRecorder? _recorder;
  StreamSubscription? _recorderSubscription;

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

  /// Native capture failure after start (record-package path). flutter_sound
  /// surfaced these by throwing from startRecorder; record reports them
  /// asynchronously on its state stream — unobserved, a failed start would
  /// look like a silent recording that never produces audio.
  Function(String error)? onCaptureError;

  Timer? _chunkTimer;
  // Audio captured since the last chunk tick. BytesBuilder(copy: false) keeps
  // the incoming Uint8List references and concatenates once per tick — no
  // per-byte copying into a growable List<int>.
  final BytesBuilder _pending = BytesBuilder(copy: false);
  bool _isInitialized = false;

  // When the recorder last delivered data — used by [isCapturingHealthy].
  DateTime? _lastDataAt;

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
    } else {
      _recorder = FlutterSoundRecorder();
      await _recorder!.openRecorder();
    }
    _isInitialized = true;
  }

  bool get isRecording => _chunkTimer != null;

  /// Whether capture is running AND the recorder delivered data recently.
  /// Used on app-resume to decide if the recorder survived the background
  /// stint (Android, where the foreground service keeps it alive) or must be
  /// restarted (iOS suspension kills audio; some Android OEMs do too).
  bool get isCapturingHealthy =>
      isRecording &&
      _lastDataAt != null &&
      DateTime.now().difference(_lastDataAt!) < const Duration(seconds: 2);

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

    // Stop any existing capture first. Raw teardown, not stop() — stop()
    // bumps the abort generation and awaits _starting, i.e. ourselves.
    if (isRecording) await _teardown();
    if (!_isInitialized) await init();
    _pending.clear();
    _speakerPending.clear();

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
        await _startIosCapture(gen);
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
  }

  Future<void> _startIosCapture(int gen) async {
    if (_wantMic) {
      await _startWithFlutterSound(gen);
      if (gen != _stopGen) return;
    }
    if (_wantSpeaker && DesktopAudioDevices.nativeLoopbackSupported) {
      await DesktopAudioDevices.startLoopback(
        deviceId: _desktop?.speakerDeviceId,
      );
      if (gen != _stopGen) {
        await DesktopAudioDevices.stopLoopback();
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
    final rec.InputDevice? device = (deviceId != null && deviceId.isNotEmpty)
        ? rec.InputDevice(id: deviceId, label: deviceId)
        : null;
    final stream = await recorder.startStream(
      rec.RecordConfig(
        encoder: rec.AudioEncoder.pcm16bits,
        sampleRate: AppConstants.sampleRate,
        numChannels: AppConstants.numChannels,
        device: device,
        // Match the capture behavior the app has always had on Android
        // (raw default mic, no session effects): the record package would
        // otherwise start a Bluetooth SCO link whenever a headset is
        // connected, silently switching capture to the low-bandwidth
        // headset mic.
        androidConfig: const rec.AndroidRecordConfig(
          manageBluetooth: false,
          audioSource: rec.AndroidAudioSource.defaultSource,
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
      _pending.add(data);
    });
    _stateErrorSub = recorder.onStateChanged().listen(
          (_) {},
          onError: (Object e) => onCaptureError?.call(_captureErrorText(e)),
        );
  }

  Future<void> _startWithFlutterSound(int gen) async {
    final controller = StreamController<Uint8List>();
    _recorderSubscription = controller.stream.listen((data) {
      _lastDataAt = DateTime.now();
      _pending.add(data);
    });

    await _recorder!.startRecorder(
      toStream: controller.sink,
      codec: Codec.pcm16,
      numChannels: AppConstants.numChannels,
      sampleRate: AppConstants.sampleRate,
    );
    if (gen != _stopGen) {
      // A stop() intervened while the native start was in flight.
      unawaited(_recorder!.stopRecorder().catchError((_) => null));
      _recorderSubscription?.cancel();
      _recorderSubscription = null;
    }
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
    if (_wantSpeaker && DesktopAudioDevices.nativeLoopbackSupported) {
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
        _speakerPending.add(extra);
      }
    } catch (e) {
      onCaptureError?.call(_captureErrorText(e));
    }
    _flushPending();
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

  Future<void> _teardown() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;

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
    if (DesktopAudioDevices.nativeLoopbackSupported) {
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
        // the instance. Mirrors the isRecording guard on the iOS branch.
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
      _recorderSubscription?.cancel();
      _recorderSubscription = null;
      if (_recorder != null && _recorder!.isRecording) {
        await _recorder!.stopRecorder();
      }
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

    // Write 44-byte WAV header
    final header = _buildWavHeader(_pcmBytesWritten);
    await outRaf.writeFrom(header);

    // Copy PCM data from temp file in chunks (avoids loading entire file)
    if (_tempFilePath != null && await File(_tempFilePath!).exists()) {
      final inStream = File(_tempFilePath!).openRead();
      await for (final chunk in inStream) {
        await outRaf.writeFrom(chunk);
      }
      // Clean up temp file
      try {
        await File(_tempFilePath!).delete();
      } catch (_) {}
    }

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

    return buffer.buffer.asUint8List();
  }

  Future<void> dispose() async {
    await stop();
    clearRecording();
    if (_isInitialized) {
      if (_useRecord) {
        await _streamRecorder?.dispose();
        _streamRecorder = null;
      } else {
        await _recorder?.closeRecorder();
        _recorder = null;
      }
      _isInitialized = false;
    }
  }
}
