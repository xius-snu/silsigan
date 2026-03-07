import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/transcript_session.dart';
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
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

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
    if (_playerInitialized) {
      _player.closePlayer();
    }
    super.dispose();
  }

  void _selectSession(TranscriptSession session) async {
    // Stop any playing audio when switching
    if (_isPlaying) {
      await _player.stopPlayer();
    }
    setState(() {
      _selectedSession = session;
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
    setState(() {
      _selectedSession = null;
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

  Future<void> _exportSessions() async {
    try {
      final filePath = await DatabaseService.instance.exportAllSessionsAsJson();
      await Share.shareXFiles(
        [XFile(filePath)],
        subject: 'Silsigan Export',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
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
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _selectedSession == null
              ? _buildListView(scrollController)
              : _buildDetailView(scrollController),
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
              const Spacer(),
              GestureDetector(
                onTap: _exportSessions,
                child: const Icon(
                  Icons.ios_share,
                  size: 22,
                  color: AppConstants.textSecondary,
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
        ],
      ),
    );
  }

  Widget _buildTextBox({
    required String label,
    required List<String> lines,
    required String fullText,
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
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                line,
                style: const TextStyle(
                  fontSize: AppConstants.contentFontSize,
                  color: AppConstants.textPrimary,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
