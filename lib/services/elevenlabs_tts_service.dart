import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:http/http.dart' as http;

class ElevenLabsTtsService {
  static const _voiceId = 'A5w1fw5x0uXded1LDvZp';
  static const _modelId = 'eleven_v3';
  static const _apiUrl = 'https://api.elevenlabs.io/v1/text-to-speech';
  static const _apiKey = String.fromEnvironment('ELEVENLABS_API_KEY');

  FlutterSoundPlayer? _player;
  final Queue<String> _queue = Queue();
  bool _isProcessing = false;
  bool _enabled = false;
  Completer<void>? _playbackCompleter;

  bool get enabled => _enabled;
  static bool get hasApiKey => _apiKey.isNotEmpty;

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

  Future<void> _ensurePlayerOpen() async {
    if (_player == null) {
      _player = FlutterSoundPlayer();
      await _player!.openPlayer();
    }
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _queue.isEmpty) return;
    _isProcessing = true;

    while (_queue.isNotEmpty && _enabled) {
      final text = _queue.removeFirst();
      try {
        await _synthesizeAndPlay(text);
      } catch (_) {
        // Silently fail — don't disrupt user experience
      }
    }

    _isProcessing = false;
  }

  Future<void> _synthesizeAndPlay(String text) async {
    await _ensurePlayerOpen();

    final url = Uri.parse('$_apiUrl/$_voiceId');
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

    if (response.statusCode == 200 && _enabled) {
      _playbackCompleter = Completer<void>();
      await _player!.startPlayer(
        fromDataBuffer: response.bodyBytes,
        codec: Codec.mp3,
        whenFinished: () {
          if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
            _playbackCompleter!.complete();
          }
        },
      );
      await _playbackCompleter!.future;
      _playbackCompleter = null;
    }
  }

  Future<void> _stopPlayback() async {
    try {
      if (_player != null && _player!.isPlaying) {
        await _player!.stopPlayer();
      }
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
    if (_player != null) {
      try {
        await _player!.closePlayer();
      } catch (_) {}
      _player = null;
    }
  }
}
