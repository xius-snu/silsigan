import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';

/// History-sheet playback.
///
/// flutter_sound ships no Windows or macOS plugin, so those builds cannot
/// use it. macOS plays the WAV through audioplayers (AVPlayer). Windows
/// Media Foundation — what audioplayers uses there — rejects these 24 kHz
/// PCM recordings, so Windows streams them with waveOut instead.
class SessionAudioPlayer {
  static const _channel = MethodChannel('com.silsigan.app/desktop_audio');

  FlutterSoundPlayer? _fs;
  AudioPlayer? _ap;
  StreamSubscription<Duration>? _apPosSub;
  StreamSubscription<Duration>? _apDurSub;
  StreamSubscription<void>? _apCompleteSub;
  Duration _apDuration = Duration.zero;
  bool _apPaused = false;
  VoidCallback? _whenFinished;

  Timer? _wavePoll;
  bool _wavePaused = false;
  bool _suppressFinish = false;
  void Function(Duration position, Duration duration)? _onProgress;

  bool get _waveOut => !kIsWeb && Platform.isWindows;

  bool get _audioPlayers => !kIsWeb && (Platform.isMacOS || Platform.isLinux);

  bool get isPaused => _waveOut
      ? _wavePaused
      : (_audioPlayers ? _apPaused : (_fs?.isPaused ?? false));

  Future<void> openPlayer({
    required void Function(Duration position, Duration duration) onProgress,
  }) async {
    _onProgress = onProgress;
    if (_waveOut) return;
    if (_audioPlayers) {
      final ap = AudioPlayer();
      _ap = ap;
      _apDurSub = ap.onDurationChanged.listen((d) {
        _apDuration = d;
      });
      _apPosSub = ap.onPositionChanged.listen((p) {
        onProgress(p, _apDuration);
      });
      _apCompleteSub = ap.onPlayerComplete.listen((_) {
        _apPaused = false;
        _whenFinished?.call();
      });
      try {
        await ap.setReleaseMode(ReleaseMode.stop);
      } catch (_) {}
      return;
    }
    final fs = FlutterSoundPlayer();
    _fs = fs;
    await fs.openPlayer();
    fs.setSubscriptionDuration(const Duration(milliseconds: 100));
    fs.onProgress?.listen((event) {
      onProgress(event.position, event.duration);
    });
  }

  Future<void> closePlayer() async {
    _wavePoll?.cancel();
    _wavePoll = null;
    _suppressFinish = true;
    if (_waveOut) {
      try {
        await _channel.invokeMethod<void>('stopWav');
      } catch (_) {}
      return;
    }
    if (_audioPlayers) {
      await _apPosSub?.cancel();
      await _apDurSub?.cancel();
      await _apCompleteSub?.cancel();
      _apPosSub = null;
      _apDurSub = null;
      _apCompleteSub = null;
      await _ap?.dispose();
      _ap = null;
      return;
    }
    await _fs?.closePlayer();
    _fs = null;
  }

  Future<void> stopPlayer() async {
    _wavePaused = false;
    _apPaused = false;
    _suppressFinish = true;
    _wavePoll?.cancel();
    _wavePoll = null;
    if (_waveOut) {
      await _channel.invokeMethod<void>('stopWav');
      return;
    }
    if (_audioPlayers) {
      await _ap?.stop();
      return;
    }
    await _fs?.stopPlayer();
  }

  Future<void> pausePlayer() async {
    if (_waveOut) {
      _wavePaused = true;
      await _channel.invokeMethod<void>('pauseWav');
      return;
    }
    if (_audioPlayers) {
      await _ap?.pause();
      _apPaused = true;
      return;
    }
    await _fs?.pausePlayer();
  }

  Future<void> resumePlayer() async {
    if (_waveOut) {
      _wavePaused = false;
      _suppressFinish = false;
      await _channel.invokeMethod<void>('resumeWav');
      _startWavePoll();
      return;
    }
    if (_audioPlayers) {
      _apPaused = false;
      await _ap?.resume();
      return;
    }
    await _fs?.resumePlayer();
  }

  Future<void> startPlayer({
    required String fromURI,
    Codec? codec,
    VoidCallback? whenFinished,
  }) async {
    _whenFinished = whenFinished;
    if (_waveOut) {
      _wavePaused = false;
      _suppressFinish = false;
      await _channel.invokeMethod<void>('playWav', {'path': fromURI});
      _startWavePoll();
      return;
    }
    if (_audioPlayers) {
      _apPaused = false;
      await _ap!.play(DeviceFileSource(fromURI, mimeType: 'audio/wav'));
      return;
    }
    await _fs!.startPlayer(
      fromURI: fromURI,
      codec: codec ?? Codec.pcm16WAV,
      whenFinished: whenFinished,
    );
  }

  Future<void> seekToPlayer(Duration position) async {
    if (_waveOut) {
      await _channel.invokeMethod<void>('seekWav', {
        'positionMs': position.inMilliseconds,
      });
      return;
    }
    if (_audioPlayers) {
      await _ap?.seek(position);
      return;
    }
    await _fs?.seekToPlayer(position);
  }

  void _startWavePoll() {
    _wavePoll?.cancel();
    _wavePoll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      unawaited(_pollWave());
    });
  }

  Future<void> _pollWave() async {
    if (_suppressFinish) return;
    final Map<Object?, Object?>? status;
    try {
      status = await _channel.invokeMapMethod<Object?, Object?>('wavStatus');
    } catch (_) {
      return;
    }
    if (status == null || _suppressFinish) return;
    final position = Duration(milliseconds: _asInt(status['positionMs']));
    final duration = Duration(milliseconds: _asInt(status['durationMs']));
    _onProgress?.call(position, duration);
    if (status['finished'] == true && !_suppressFinish) {
      _suppressFinish = true;
      _wavePaused = false;
      _wavePoll?.cancel();
      _wavePoll = null;
      _whenFinished?.call();
    }
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}
