import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../utils/constants.dart';
import 'user_service.dart';

enum TtsLineStatus { idle, loading, playing }

/// Soniox Text-to-Speech via our own server proxy.
/// Voice: Maya (single voice across all supported languages).
/// Model: tts-rt-v1.
class SonioxTtsService {
  static const _voice = 'Maya';
  static const _model = 'tts-rt-v1';

  /// Languages we ship voices for. Soniox supports more, but the app
  /// scopes itself to these eight.
  static const _supportedLangs = {
    'ko', 'en', 'vi', 'tr', 'zh', 'ja', 'th', 'ms',
  };

  String _languageCode = 'vi';

  final AudioPlayer _player = AudioPlayer();
  final Queue<String> _queue = Queue();
  bool _isProcessing = false;
  bool _enabled = false;
  Completer<void>? _playbackCompleter;

  Function(String error)? onError;
  Function(bool playing)? onPlaybackStateChanged;

  final lineState = ValueNotifier<({String? text, TtsLineStatus status})>(
      (text: null, status: TtsLineStatus.idle));

  bool get enabled => _enabled;

  /// True iff the proxy URL is configured. Auth happens via the user's
  /// existing Bearer token, so no app-side key check is needed.
  static bool get hasApiKey => AppConstants.serverBaseUrl.isNotEmpty;

  static bool supportsLanguage(String code) => _supportedLangs.contains(code);

  SonioxTtsService() {
    _player.onPlayerComplete.listen((_) {
      if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
        _playbackCompleter!.complete();
      }
    });
  }

  void setLanguageCode(String code) {
    _languageCode = code;
  }

  void setEnabled(bool value) {
    _enabled = value;
    if (!value) {
      _queue.clear();
      _stopPlayback();
    }
  }

  void speak(String text) {
    if (!_enabled || text.trim().isEmpty) return;
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
    final lang =
        _supportedLangs.contains(_languageCode) ? _languageCode : 'en';
    final url = Uri.parse('${AppConstants.serverBaseUrl}/api/tts');
    final token = UserService.instance.authToken;
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'userId': UserService.instance.userId,
        'text': text,
        'language': lang,
        'voice': _voice,
        'model': _model,
      }),
    );

    if (response.statusCode != 200) {
      final body = response.body.length > 200
          ? response.body.substring(0, 200)
          : response.body;
      onError?.call('Soniox TTS ${response.statusCode}: $body');
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final tempFile = File(
        '${tempDir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
    await tempFile.writeAsBytes(response.bodyBytes);

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

    try {
      await tempFile.delete();
    } catch (_) {}
  }

  Future<void> speakOnce(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    if (lineState.value.text == trimmed &&
        lineState.value.status == TtsLineStatus.playing) {
      await _stopPlayback();
      lineState.value = (text: null, status: TtsLineStatus.idle);
      return;
    }

    if (lineState.value.status == TtsLineStatus.loading) return;

    _queue.clear();
    await _stopPlayback();
    lineState.value = (text: trimmed, status: TtsLineStatus.loading);
    try {
      await _synthesizeAndPlay(trimmed);
    } catch (e) {
      onError?.call('TTS: $e');
    }
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
