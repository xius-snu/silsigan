import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:record/record.dart' as rec;
import 'package:path_provider/path_provider.dart';
import '../utils/constants.dart';

class AudioService {
  // flutter_sound (mobile)
  FlutterSoundRecorder? _recorder;
  StreamSubscription? _recorderSubscription;

  // record package (Windows)
  rec.AudioRecorder? _winRecorder;
  StreamSubscription? _winStreamSubscription;

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

  bool get _useRecord =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> init() async {
    if (_isInitialized) return;
    if (_useRecord) {
      _winRecorder = rec.AudioRecorder();
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

  Future<void> start() async {
    // Stop any existing capture first (safe to call if already stopped)
    if (isRecording) await stop();
    if (!_isInitialized) await init();
    _pending.clear();

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

    if (_useRecord) {
      await _startWithRecord();
    } else {
      await _startWithFlutterSound();
    }

    _chunkTimer = Timer.periodic(
      const Duration(milliseconds: AppConstants.chunkIntervalMs),
      (_) => _sendChunk(),
    );
  }

  Future<void> _startWithRecord() async {
    final stream = await _winRecorder!.startStream(
      const rec.RecordConfig(
        encoder: rec.AudioEncoder.pcm16bits,
        sampleRate: AppConstants.sampleRate,
        numChannels: AppConstants.numChannels,
      ),
    );
    _winStreamSubscription = stream.listen((data) {
      _lastDataAt = DateTime.now();
      _pending.add(data);
    });
  }

  Future<void> _startWithFlutterSound() async {
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
    if (_pending.isEmpty) return;
    final bytes = _pending.takeBytes();
    // One disk write per tick instead of one per recorder callback — the
    // recorder delivers many small buffers per second and each writeFromSync
    // was a blocking syscall on the UI isolate.
    _writeToDisk(bytes);
    onAudioChunk?.call(bytes);
  }

  Future<void> stop() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;

    if (_useRecord) {
      _winStreamSubscription?.cancel();
      _winStreamSubscription = null;
      await _winRecorder?.stop();
    } else {
      _recorderSubscription?.cancel();
      _recorderSubscription = null;
      if (_recorder != null && _recorder!.isRecording) {
        await _recorder!.stopRecorder();
      }
    }

    // Write the tail captured since the last chunk tick so the saved WAV
    // doesn't lose the final ≤100ms.
    if (_pending.isNotEmpty) {
      _writeToDisk(_pending.takeBytes());
    }

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
        await _winRecorder?.dispose();
        _winRecorder = null;
      } else {
        await _recorder?.closeRecorder();
        _recorder = null;
      }
      _isInitialized = false;
    }
  }
}
