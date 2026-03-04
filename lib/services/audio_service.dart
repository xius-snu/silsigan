import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/constants.dart';

class AudioService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  StreamSubscription? _recorderSubscription;
  Timer? _chunkTimer;
  final List<int> _audioBuffer = [];
  final List<int> _fullRecording = [];
  bool _isInitialized = false;

  Function(Uint8List)? onAudioChunk;

  Future<void> init() async {
    if (_isInitialized) return;
    await _recorder.openRecorder();
    _isInitialized = true;
  }

  Future<void> start() async {
    if (!_isInitialized) await init();
    _audioBuffer.clear();

    final controller = StreamController<Uint8List>();
    _recorderSubscription = controller.stream.listen((data) {
      _audioBuffer.addAll(data);
      _fullRecording.addAll(data);
    });

    await _recorder.startRecorder(
      toStream: controller.sink,
      codec: Codec.pcm16,
      numChannels: AppConstants.numChannels,
      sampleRate: AppConstants.sampleRate,
    );

    _chunkTimer = Timer.periodic(
      const Duration(milliseconds: AppConstants.chunkIntervalMs),
      (_) => _sendChunk(),
    );
  }

  void _sendChunk() {
    if (_audioBuffer.isEmpty) return;
    final bytes = Uint8List.fromList(_audioBuffer);
    _audioBuffer.clear();
    onAudioChunk?.call(bytes);
  }

  Future<void> stop() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    _recorderSubscription?.cancel();
    _recorderSubscription = null;
    if (_recorder.isRecording) {
      await _recorder.stopRecorder();
    }
  }

  /// Save accumulated PCM data as a WAV file. Returns the file path.
  Future<String> saveRecordingAsWav(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/$fileName';
    final pcmData = Uint8List.fromList(_fullRecording);
    final wavData = _buildWav(pcmData);
    await File(filePath).writeAsBytes(wavData);
    return filePath;
  }

  /// Clear the accumulated recording buffer.
  void clearRecording() {
    _fullRecording.clear();
  }

  bool get hasRecording => _fullRecording.isNotEmpty;

  Uint8List _buildWav(Uint8List pcmData) {
    const sampleRate = AppConstants.sampleRate;
    const numChannels = AppConstants.numChannels;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataSize = pcmData.length;
    final fileSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);
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
    buffer.setUint32(offset, 16, Endian.little); // chunk size
    offset += 4;
    buffer.setUint16(offset, 1, Endian.little); // PCM format
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
    buffer.setUint32(offset, dataSize, Endian.little);
    offset += 4;

    // PCM data
    for (int i = 0; i < pcmData.length; i++) {
      buffer.setUint8(offset++, pcmData[i]);
    }

    return buffer.buffer.asUint8List();
  }

  Future<void> dispose() async {
    await stop();
    if (_isInitialized) {
      await _recorder.closeRecorder();
      _isInitialized = false;
    }
  }
}
