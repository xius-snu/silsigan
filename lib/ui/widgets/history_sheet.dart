import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/transcript_session.dart';
import '../../models/word_timestamp.dart';
import '../../providers/session_history_provider.dart';
import '../../services/database_service.dart';
import '../../services/sync_service.dart';
import '../../utils/constants.dart';
import 'session_card.dart';

class HistorySheet extends ConsumerStatefulWidget {
  final double maxFraction;
  final int? initialSessionId;

  const HistorySheet({
    super.key,
    required this.maxFraction,
    this.initialSessionId,
  });

  @override
  ConsumerState<HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends ConsumerState<HistorySheet> {
  TranscriptSession? _selectedSession;

  // Audio player
  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  bool _playerInitialized = false;

  // Word timestamps for tap-to-seek (per-line, for transcription)
  List<List<WordTimestamp>>? _parsedTimestamps;
  final List<TapGestureRecognizer> _tapRecognizers = [];
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Tap highlight effect
  String? _highlightedWordId; // "lineIdx_wordIdx"
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _initPlayer();
    if (widget.initialSessionId != null) {
      _loadInitialSession(widget.initialSessionId!);
    }
    _syncFromServer();
  }

  Future<void> _syncFromServer() async {
    final anyNew = await SyncService.instance.syncFromServer();
    if (anyNew && mounted) {
      ref.invalidate(sessionHistoryProvider);
    }
  }

  Future<void> _loadInitialSession(int id) async {
    final session = await DatabaseService.instance.getSession(id);
    if (session != null && mounted) {
      _selectSession(session);
    }
  }

  Future<void> _initPlayer() async {
    await _player.openPlayer();
    _player.setSubscriptionDuration(const Duration(milliseconds: 100));
    _player.onProgress?.listen((event) {
      if (mounted) {
        setState(() {
          _position = event.position;
          if (event.duration > Duration.zero) {
            _duration = event.duration;
          }
        });
      }
    });
    _playerInitialized = true;
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _clearTapRecognizers();
    if (_playerInitialized) {
      _player.closePlayer();
    }
    super.dispose();
  }

  void _clearTapRecognizers() {
    for (final r in _tapRecognizers) {
      r.dispose();
    }
    _tapRecognizers.clear();
  }

  void _selectSession(TranscriptSession session) async {
    // Stop any playing audio when switching
    if (_isPlaying) {
      await _player.stopPlayer();
    }
    _clearTapRecognizers();
    // Parse word timestamps if available
    List<List<WordTimestamp>>? timestamps;
    if (session.timestampsJson != null) {
      try {
        final raw = jsonDecode(session.timestampsJson!) as List;
        timestamps = raw
            .map((line) => (line as List)
                .map((w) => WordTimestamp.fromJson(w as Map<String, dynamic>))
                .toList())
            .toList();
      } catch (_) {}
    }
    setState(() {
      _selectedSession = session;
      _parsedTimestamps = timestamps;
      _isPlaying = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    // Calculate duration from file
    if (session.audioPath != null) {
      final file = File(session.audioPath!);
      if (await file.exists()) {
        final fileSize = await file.length();
        final dataSize = fileSize - 44;
        final bytesPerSecond =
            AppConstants.sampleRate * AppConstants.numChannels * 2;
        final durationSecs = dataSize / bytesPerSecond;
        if (mounted) {
          setState(() {
            _duration = Duration(milliseconds: (durationSecs * 1000).round());
          });
        }
      }
    }
  }

  void _goBackToList() async {
    if (_isPlaying) {
      await _player.stopPlayer();
    }
    _clearTapRecognizers();
    setState(() {
      _selectedSession = null;
      _parsedTimestamps = null;
      _isPlaying = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
  }

  Future<void> _playPause() async {
    if (!_playerInitialized) return;
    final audioPath = _selectedSession?.audioPath;
    if (audioPath == null) return;

    if (_isPlaying) {
      await _player.pausePlayer();
      setState(() => _isPlaying = false);
    } else {
      if (_player.isPaused) {
        await _player.resumePlayer();
        setState(() => _isPlaying = true);
      } else {
        final seekTarget = _position > Duration.zero ? _position : null;
        setState(() => _isPlaying = true);
        await _player.startPlayer(
          fromURI: audioPath,
          codec: Codec.pcm16WAV,
          whenFinished: () {
            if (mounted) {
              setState(() {
                _isPlaying = false;
                _position = Duration.zero;
              });
            }
          },
        );
        // If user tapped a word before playing, seek to that position
        if (seekTarget != null) {
          await Future.delayed(const Duration(milliseconds: 50));
          await _player.seekToPlayer(seekTarget);
        }
      }
    }
  }

  Future<void> _seekRelative(int seconds) async {
    if (!_playerInitialized) return;
    if (!_isPlaying && !_player.isPaused) return;
    final newPos = _position + Duration(seconds: seconds);
    final clamped = newPos < Duration.zero
        ? Duration.zero
        : (newPos > _duration ? _duration : newPos);
    await _player.seekToPlayer(clamped);
  }

  Future<void> _seekTo(Duration position) async {
    if (!_playerInitialized) return;
    if (!_isPlaying && !_player.isPaused) return;
    await _player.seekToPlayer(position);
  }

  /// Seek audio to [ms] milliseconds.
  /// - If playing: seek and continue playing.
  /// - If paused or stopped: just update position visually (no auto-play).
  Future<void> _seekToMs(int ms) async {
    if (!_playerInitialized) return;
    final audioPath = _selectedSession?.audioPath;
    if (audioPath == null) return;

    final target = Duration(milliseconds: ms);

    if (_isPlaying) {
      // Currently playing — seek and continue
      await _player.seekToPlayer(target);
    } else if (_player.isPaused) {
      // Paused — seek but stay paused, update UI
      await _player.seekToPlayer(target);
      setState(() => _position = target);
    } else {
      // Stopped — just update position visually; will seek on next play
      setState(() => _position = target);
    }
  }

  Future<void> _shareAudio() async {
    final audioPath = _selectedSession?.audioPath;
    if (audioPath == null) return;
    final file = File(audioPath);
    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio file not found')),
        );
      }
      return;
    }
    try {
      final date = _formatDate(_selectedSession!.createdAt);
      await Share.shareXFiles(
        [XFile(audioPath, mimeType: 'audio/wav')],
        subject: 'Silsigan Audio — $date',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    }
  }

  Future<void> _deleteSession() async {
    if (_selectedSession == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Session'),
        content: const Text('Are you sure you want to delete this session?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && _selectedSession?.id != null) {
      if (_isPlaying) await _player.stopPlayer();
      final createdAt = _selectedSession!.createdAt;
      await DatabaseService.instance.deleteSession(_selectedSession!.id!);
      // Delete from server (fire-and-forget)
      SyncService.instance.deleteFromServer(createdAt);
      ref.invalidate(sessionHistoryProvider);
      _goBackToList();
    }
  }

  Future<void> _shareSession() async {
    if (_selectedSession == null) return;
    try {
      final session = _selectedSession!;
      final date = _formatDate(session.createdAt);
      final text = StringBuffer();
      text.writeln('Silsigan — $date');
      text.writeln();
      text.writeln('── TRANSCRIPTION ──');
      text.writeln(session.koreanFull);
      text.writeln();
      text.writeln('── TRANSLATION ──');
      text.writeln(session.vietnameseFull);

      final dir = Directory.systemTemp;
      final file = File('${dir.path}/silsigan_session.txt');
      await file.writeAsString(text.toString());
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/plain')],
        subject: 'Silsigan Session — $date',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    }
  }

  void _copyText(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String _formatDate(String isoDate) {
    try {
      final dt = DateTime.parse(isoDate);
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year} — $hour:$minute';
    } catch (_) {
      return isoDate;
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: widget.maxFraction,
      minChildSize: 0.4,
      maxChildSize: widget.maxFraction,
      expand: false,
      builder: (context, scrollController) {
        return PopScope(
          canPop: _selectedSession == null,
          onPopInvoked: (didPop) {
            if (!didPop && _selectedSession != null) {
              _goBackToList();
            }
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _selectedSession == null
                ? _buildListView(scrollController)
                : _buildDetailView(scrollController),
          ),
        );
      },
    );
  }

  Widget _buildListView(ScrollController scrollController) {
    final sessionsAsync = ref.watch(sessionHistoryProvider);
    return Column(
      key: const ValueKey('history-list'),
      children: [
        _buildDragHandle(),
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 12, bottom: 8),
          child: Row(
            children: [
              const Text(
                'History',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppConstants.textPrimary,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: sessionsAsync.when(
            loading: () => Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation(AppConstants.textPrimary),
              ),
            ),
            error: (error, _) => Center(
              child: Text(
                'Failed to load sessions',
                style: TextStyle(
                  color: AppConstants.textSecondary.withOpacity(0.6),
                ),
              ),
            ),
            data: (sessions) {
              if (sessions.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.mic_none_rounded,
                        size: 80,
                        color: AppConstants.textSecondary.withOpacity(0.25),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No saved sessions yet',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: AppConstants.textSecondary.withOpacity(0.7),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Start recording to create your first session',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppConstants.textSecondary.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: sessions.length,
                itemBuilder: (context, index) {
                  final session = sessions[index];
                  return SessionCard(
                    session: session,
                    onTap: () => _selectSession(session),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDetailView(ScrollController scrollController) {
    final session = _selectedSession!;
    final koreanLines = session.koreanFull.split('\n');
    final vietnameseLines = session.vietnameseFull.split('\n');
    final hasAudio = session.audioPath != null;

    return Column(
      key: const ValueKey('history-detail'),
      children: [
        _buildDragHandle(),
        // Header with back, date, delete
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                color: AppConstants.textPrimary,
                onPressed: _goBackToList,
              ),
              Expanded(
                child: Text(
                  _formatDate(session.createdAt),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppConstants.textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.ios_share),
                color: AppConstants.textSecondary,
                iconSize: 22,
                onPressed: _shareSession,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: _deleteSession,
              ),
            ],
          ),
        ),
        // Content
        Expanded(
          child: SelectionArea(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTextBox(
                    label: 'TRANSCRIPTION',
                    lines: koreanLines,
                    fullText: session.koreanFull,
                    timestamps: hasAudio ? _parsedTimestamps : null,
                  ),
                  const SizedBox(height: 5),
                  _buildTextBox(
                    label: 'TRANSLATION',
                    lines: vietnameseLines,
                    fullText: session.vietnameseFull,
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
        // Audio player
        if (hasAudio) _buildAudioPlayer(),
      ],
    );
  }

  Widget _buildDragHandle() {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: AppConstants.textSecondary.withOpacity(0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  Widget _buildAudioPlayer() {
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    return Container(
      color: AppConstants.panelColor,
      padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: AppConstants.textPrimary,
              inactiveTrackColor: AppConstants.textPrimary.withOpacity(0.2),
              thumbColor: AppConstants.textPrimary,
            ),
            child: Slider(
              value: progress.clamp(0.0, 1.0),
              onChanged: (value) {
                final newPos = Duration(
                  milliseconds: (value * _duration.inMilliseconds).round(),
                );
                _seekTo(newPos);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_position),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppConstants.textSecondary.withOpacity(0.7),
                  ),
                ),
                Text(
                  _formatDuration(_duration),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppConstants.textSecondary.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 48),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.replay_10),
                      iconSize: 32,
                      color: AppConstants.textPrimary,
                      onPressed: () => _seekRelative(-10),
                    ),
                    const SizedBox(width: 24),
                    GestureDetector(
                      onTap: _playPause,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppConstants.textPrimary,
                        ),
                        child: Icon(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                          size: 30,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    IconButton(
                      icon: const Icon(Icons.forward_10),
                      iconSize: 32,
                      color: AppConstants.textPrimary,
                      onPressed: () => _seekRelative(10),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.download_rounded),
                iconSize: 24,
                color: AppConstants.textSecondary,
                onPressed: _shareAudio,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTextBox({
    required String label,
    required List<String> lines,
    required String fullText,
    List<List<WordTimestamp>>? timestamps,
  }) {
    final hasText = fullText.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppConstants.panelPaddingH),
      decoration: BoxDecoration(
        color: AppConstants.panelColor,
        borderRadius: BorderRadius.circular(AppConstants.panelBorderRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: AppConstants.labelFontSize,
                  fontWeight: FontWeight.w400,
                  color: AppConstants.textSecondary,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              if (hasText)
                GestureDetector(
                  onTap: () => _copyText(fullText, label),
                  child: const Icon(
                    Icons.copy,
                    size: 18,
                    color: AppConstants.textSecondary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ...lines.asMap().entries.map((entry) {
            final lineIdx = entry.key;
            final line = entry.value;

            // If we have timestamps for this line, build tappable word spans
            if (timestamps != null &&
                lineIdx < timestamps.length &&
                timestamps[lineIdx].isNotEmpty) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text.rich(
                  _buildTappableSpans(lineIdx, line, timestamps[lineIdx]),
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                line,
                style: const TextStyle(
                  fontSize: AppConstants.contentFontSize,
                  color: AppConstants.textPrimary,
                  height: 1.5,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  void _onWordTap(int lineIdx, int wordIdx, int startMs) {
    HapticFeedback.selectionClick();
    _seekToMs(startMs);
    // Flash highlight
    setState(() => _highlightedWordId = '${lineIdx}_$wordIdx');
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _highlightedWordId = null);
    });
  }

  /// Build a TextSpan where each word with a timestamp is tappable.
  /// Words are matched sequentially: walk through the line text finding each
  /// timestamp token, making matched portions tappable and gaps plain text.
  TextSpan _buildTappableSpans(
      int lineIdx, String line, List<WordTimestamp> words) {
    final spans = <InlineSpan>[];
    int cursor = 0;
    int wordIdx = 0;

    const baseStyle = TextStyle(
      fontSize: AppConstants.contentFontSize,
      color: AppConstants.textPrimary,
      height: 1.5,
    );

    const highlightStyle = TextStyle(
      fontSize: AppConstants.contentFontSize,
      color: AppConstants.textPrimary,
      height: 1.5,
      backgroundColor: Color(0x30000000),
    );

    for (final wt in words) {
      final token = wt.text;
      if (token.isEmpty) continue;

      // Find this token in the remaining line text
      final idx = line.indexOf(token, cursor);
      if (idx < 0) continue;

      // Add any text before this token as plain text
      if (idx > cursor) {
        spans.add(TextSpan(
          text: line.substring(cursor, idx),
          style: baseStyle,
        ));
      }

      // Add the tappable word with highlight support
      final currentWordIdx = wordIdx;
      final isHighlighted = _highlightedWordId == '${lineIdx}_$currentWordIdx';
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _onWordTap(lineIdx, currentWordIdx, wt.startMs);
      _tapRecognizers.add(recognizer);

      spans.add(TextSpan(
        text: token,
        style: isHighlighted ? highlightStyle : baseStyle,
        recognizer: recognizer,
      ));

      cursor = idx + token.length;
      wordIdx++;
    }

    // Add any remaining text after the last matched token
    if (cursor < line.length) {
      spans.add(TextSpan(
        text: line.substring(cursor),
        style: baseStyle,
      ));
    }

    return TextSpan(children: spans);
  }
}
