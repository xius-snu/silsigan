import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum TtsLineStatus { idle, loading, playing }

class ElevenLabsTtsService {
  static const _modelId = 'eleven_flash_v2_5';
  static const _apiUrl = 'https://api.elevenlabs.io/v1/text-to-speech';
  static const _apiKey = String.fromEnvironment('ELEVENLABS_API_KEY');

  /// Voice IDs per language code.
  static const _voices = <String, String>{
    'vi': 'A5w1fw5x0uXded1LDvZp',
    'ko': 'QPFsEL6IBxlT15xfiD6C',
    'en': '21m00Tcm4TlvDq8ikWAM',
    'tr': 'ErXwobaYiN019PkySvjV',
    'zh': 'pNInz6obpgDQGcFmaJgB',
  };

  /// The language code currently used for TTS (determines voice + language_code).
  String _languageCode = 'vi';

  final AudioPlayer _player = AudioPlayer();
  final Queue<String> _queue = Queue();
  bool _isProcessing = false;
  bool _enabled = false;
  Completer<void>? _playbackCompleter;

  Function(String error)? onError;

  /// Called when TTS playback starts/stops — useful for muting mic during TTS.
  Function(bool playing)? onPlaybackStateChanged;

  /// Tracks per-line TTS state for UI (loading spinner / stop button).
  final lineState = ValueNotifier<({String? text, TtsLineStatus status})>(
      (text: null, status: TtsLineStatus.idle));

  bool get enabled => _enabled;
  static bool get hasApiKey => _apiKey.isNotEmpty;

  ElevenLabsTtsService() {
    _player.onPlayerComplete.listen((_) {
      if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
        _playbackCompleter!.complete();
      }
    });
  }

  void setLanguageCode(String code) {
    _languageCode = code;
  }

  /// Whether TTS is supported for the given language code.
  static bool supportsLanguage(String code) => _voices.containsKey(code);

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
    final voiceId = _voices[_languageCode] ?? _voices['vi']!;
    final url = Uri.parse(
        '$_apiUrl/$voiceId?optimize_streaming_latency=3&output_format=mp3_22050_32');
    final response = await http.post(
      url,
      headers: {
        'xi-api-key': _apiKey,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'text': text,
        'model_id': _modelId,
        'language_code': _languageCode,
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
    final tempFile = File(
        '${tempDir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
    await tempFile.writeAsBytes(response.bodyBytes);

    // Transition to playing state (for per-line icon)
    if (lineState.value.text != null) {
      lineState.value =
          (text: lineState.value.text, status: TtsLineStatus.playing);
    }

    _playbackCompleter = Completer<void>();
    onPlaybackStateChanged?.call(true);
    await _player.play(DeviceFileSource(tempFile.path));
    await _playbackCompleter!.future;
    _playbackCompleter = null;
    onPlaybackStateChanged?.call(false);

    // Clean up temp file
    try {
      await tempFile.delete();
    } catch (_) {}
  }

  /// Manual one-off TTS — works regardless of auto-TTS toggle.
  /// Tap while playing → stop. Tap while idle → play with loading state.
  Future<void> speakOnce(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !hasApiKey) return;

    // Tapping while playing this line → stop
    if (lineState.value.text == trimmed &&
        lineState.value.status == TtsLineStatus.playing) {
      await _stopPlayback();
      lineState.value = (text: null, status: TtsLineStatus.idle);
      return;
    }

    // Ignore tap while loading
    if (lineState.value.status == TtsLineStatus.loading) return;

    _queue.clear();
    await _stopPlayback();
    lineState.value = (text: trimmed, status: TtsLineStatus.loading);
    try {
      await _synthesizeAndPlay(trimmed);
    } catch (e) {
      onError?.call('TTS: $e');
    }
    // Only reset if this line is still the active one
    if (lineState.value.text == trimmed) {
      lineState.value = (text: null, status: TtsLineStatus.idle);
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
    onPlaybackStateChanged?.call(false);
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
