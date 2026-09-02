import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';

/// History-sheet playback. flutter_sound has no Windows plugin, so desktop
/// uses [audioplayers] (already a dependency) against the same WAV files.
class SessionAudioPlayer {
  FlutterSoundPlayer? _fs;
  AudioPlayer? _ap;
  StreamSubscription<Duration>? _apPosSub;
  StreamSubscription<Duration>? _apDurSub;
  StreamSubscription<void>? _apCompleteSub;
  Duration _apDuration = Duration.zero;
  bool _apPaused = false;
  VoidCallback? _whenFinished;

  bool get _desktop => !kIsWeb && (Platform.isWindows || Platform.isLinux);

  bool get isPaused => _desktop ? _apPaused : (_fs?.isPaused ?? false);

  Future<void> openPlayer({
    required void Function(Duration position, Duration duration) onProgress,
  }) async {
    if (_desktop) {
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
    if (_desktop) {
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
    _apPaused = false;
    if (_desktop) {
      await _ap?.stop();
      return;
    }
    await _fs?.stopPlayer();
  }

  Future<void> pausePlayer() async {
    if (_desktop) {
      await _ap?.pause();
      _apPaused = true;
      return;
    }
    await _fs?.pausePlayer();
  }

  Future<void> resumePlayer() async {
    if (_desktop) {
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
    if (_desktop) {
      _apPaused = false;
      await _ap!.play(DeviceFileSource(fromURI));
      return;
    }
    await _fs!.startPlayer(
      fromURI: fromURI,
      codec: codec ?? Codec.pcm16WAV,
      whenFinished: whenFinished,
    );
  }

  Future<void> seekToPlayer(Duration position) async {
    if (_desktop) {
      await _ap?.seek(position);
      return;
    }
    await _fs?.seekToPlayer(position);
  }
}
