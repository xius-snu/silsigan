import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum TtsLineStatus { idle, loading, playing }

/// Native OS TTS via flutter_tts. iOS uses AVSpeechSynthesizer, Android uses
/// the system TTS engine (usually Google TTS). Free, offline once voices are
/// installed, no API key.
class TtsService {
  /// ISO 639-1 -> BCP-47 locale that the OS expects.
  static const _langMap = <String, String>{
    'ko': 'ko-KR',
    'en': 'en-US',
    'vi': 'vi-VN',
    'tr': 'tr-TR',
    'zh': 'zh-CN',
    'ja': 'ja-JP',
    'th': 'th-TH',
    'ms': 'ms-MY',
  };

  final FlutterTts _tts = FlutterTts();
  final Queue<String> _queue = Queue();

  String _languageCode = 'vi';
  double _rateMultiplier = 1.0;
  bool _enabled = false;
  bool _isProcessing = false;
  bool _isInitialized = false;
  Completer<void>? _playbackCompleter;

  Function(String error)? onError;
  Function(bool playing)? onPlaybackStateChanged;

  final lineState = ValueNotifier<({String? text, TtsLineStatus status})>(
      (text: null, status: TtsLineStatus.idle));

  bool get enabled => _enabled;

  /// Always available — no key needed.
  static bool get hasApiKey => true;

  static bool supportsLanguage(String code) => _langMap.containsKey(code);

  TtsService() {
    _tts.setStartHandler(() {
      if (lineState.value.text != null) {
        lineState.value =
            (text: lineState.value.text, status: TtsLineStatus.playing);
      }
      onPlaybackStateChanged?.call(true);
    });
    _tts.setCompletionHandler(() {
      _completePlayback();
    });
    _tts.setCancelHandler(() {
      _completePlayback();
    });
    _tts.setErrorHandler((msg) {
      onError?.call('TTS: $msg');
      _completePlayback();
    });
  }

  void _completePlayback() {
    if (_playbackCompleter != null && !_playbackCompleter!.isCompleted) {
      _playbackCompleter!.complete();
    }
    _playbackCompleter = null;
    onPlaybackStateChanged?.call(false);
  }

  /// One-time iOS audio session setup so TTS playback can coexist with the
  /// recorder without taking over the audio output.
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;
    _isInitialized = true;
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
            IosTextToSpeechAudioCategoryOptions.duckOthers,
          ],
          IosTextToSpeechAudioMode.defaultMode,
        );
      }
      await _tts.awaitSpeakCompletion(false);
    } catch (e) {
      onError?.call('TTS init: $e');
    }
  }

  void setLanguageCode(String code) {
    _languageCode = code;
  }

  /// Speed multiplier (clamped 0.5 - 1.5) applied at speak-time.
  void setRate(double multiplier) {
    _rateMultiplier = multiplier.clamp(0.5, 1.5);
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
        await _ttsSpeak(text);
      } catch (e) {
        onError?.call('TTS: $e');
      }
    }
    _isProcessing = false;
  }

  Future<void> _ttsSpeak(String text) async {
    await _ensureInitialized();
    final lang = _langMap[_languageCode] ?? 'en-US';
    try {
      await _tts.setLanguage(lang);
    } catch (_) {
      // Some devices don't ship the requested locale — let the OS fall back
      // to the closest available voice for that language.
    }
    // iOS rate is 0..1 with ~0.5 = natural; Android rate is 0..2 with 1.0 = natural.
    // Slower than natural — language learners benefit from extra clarity.
    final base = defaultTargetPlatform == TargetPlatform.iOS ? 0.45 : 0.75;
    final maxRate = defaultTargetPlatform == TargetPlatform.iOS ? 1.0 : 2.0;
    final rate = (base * _rateMultiplier).clamp(0.0, maxRate);
    await _tts.setSpeechRate(rate);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);

    _playbackCompleter = Completer<void>();
    final result = await _tts.speak(text);
    if (result == 1) {
      await _playbackCompleter!.future;
    } else {
      _playbackCompleter = null;
    }
  }

  /// Manual one-off TTS. Tap while playing this line → stop.
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
      await _ttsSpeak(trimmed);
    } catch (e) {
      onError?.call('TTS: $e');
    }
    if (lineState.value.text == trimmed) {
      lineState.value = (text: null, status: TtsLineStatus.idle);
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _completePlayback();
  }

  Future<void> stop() async {
    _enabled = false;
    _queue.clear();
    await _stopPlayback();
  }

  Future<void> dispose() async {
    await stop();
  }
}
