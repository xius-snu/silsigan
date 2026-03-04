import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import '../utils/constants.dart';

class AudioService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  StreamSubscription? _recorderSubscription;
  Timer? _chunkTimer;
  final List<int> _audioBuffer = [];
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

  Future<void> dispose() async {
    await stop();
    if (_isInitialized) {
      await _recorder.closeRecorder();
      _isInitialized = false;
    }
  }
}
