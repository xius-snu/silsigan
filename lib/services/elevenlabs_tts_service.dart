import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ElevenLabsTtsService {
  static const _voiceId = 'A5w1fw5x0uXded1LDvZp';
  static const _modelId = 'eleven_flash_v2_5';
  static const _apiUrl = 'https://api.elevenlabs.io/v1/text-to-speech';
  static const _apiKey = String.fromEnvironment('ELEVENLABS_API_KEY');

  final AudioPlayer _player = AudioPlayer();
  final Queue<String> _queue = Queue();
  bool _isProcessing = false;
  bool _enabled = false;
  Completer<void>? _playbackCompleter;

  Function(String error)? onError;

  bool get enabled => _enabled;
  static bool get hasApiKey => _apiKey.isNotEmpty;

  ElevenLabsTtsService() {
    _player.onPlayerComplete.listen((_) {
      if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
        _playbackCompleter!.complete();
      }
    });
  }

  void setEnabled(bool value) {
    _enabled = value;
    if (!value) {
      _queue.clear();
      _stopPlayback();
    }
  }

  void speak(String text) {
    if (!_enabled || text.trim().isEmpty || !hasApiKey) return;
    _queue.add(text.trim());
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _queue.isEmpty) return;
    _isProcessing = true;

    while (_queue.isNotEmpty && _enabled) {
      final text = _queue.removeFirst();
      try {
        await _synthesizeAndPlay(text);
      } catch (e) {
        onError?.call('TTS: $e');
      }
    }

    _isProcessing = false;
  }

  Future<void> _synthesizeAndPlay(String text) async {
    final url = Uri.parse(
        '$_apiUrl/$_voiceId?optimize_streaming_latency=3&output_format=mp3_22050_32');
    final response = await http.post(
      url,
      headers: {
        'xi-api-key': _apiKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'text': text,
        'model_id': _modelId,
        'language_code': 'vi',
        'voice_settings': {
          'stability': 0.5,
          'similarity_boost': 0.75,
        },
      }),
    );

    if (response.statusCode != 200) {
      final body = response.body.length > 200
          ? response.body.substring(0, 200)
          : response.body;
      onError?.call('ElevenLabs ${response.statusCode}: $body');
      return;
    }

    // Save to temp file for reliable playback alongside active recorder
    final tempDir = await getTemporaryDirectory();
    final tempFile =
        File('${tempDir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
    await tempFile.writeAsBytes(response.bodyBytes);

    _playbackCompleter = Completer<void>();
    await _player.play(DeviceFileSource(tempFile.path));
    await _playbackCompleter!.future;
    _playbackCompleter = null;

    // Clean up temp file
    try {
      await tempFile.delete();
    } catch (_) {}
  }

  /// Manual one-off TTS — works regardless of auto-TTS toggle.
  /// Stops any current playback and plays immediately.
  Future<void> speakOnce(String text) async {
    if (text.trim().isEmpty || !hasApiKey) return;
    _queue.clear();
    await _stopPlayback();
    try {
      await _synthesizeAndPlay(text.trim());
    } catch (e) {
      onError?.call('TTS: $e');
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await _player.stop();
    } catch (_) {}
    if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
      _playbackCompleter!.complete();
    }
    _playbackCompleter = null;
  }

  Future<void> stop() async {
    _enabled = false;
    _queue.clear();
    await _stopPlayback();
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}
