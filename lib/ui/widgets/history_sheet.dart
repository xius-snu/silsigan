import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
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
import '../../services/user_service.dart';
import '../../utils/constants.dart';
import '../../utils/text_direction_utils.dart';
import 'session_card.dart';

/// Isolate entry for parsing a saved session's per-word timestamps — the JSON
/// carries one entry per word, so a long session decoded inline janked the
/// open animation.
List<List<WordTimestamp>> _parseTimestampsJson(String json) {
  final raw = jsonDecode(json) as List;
  return raw
      .map((line) => (line as List)
          .map((w) => WordTimestamp.fromJson(w as Map<String, dynamic>))
          .toList())
      .toList();
}

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
  bool _isPlaying = false;

  // Playback position/duration as notifiers, NOT setState fields: the
  // progress stream ticks at 10Hz during playback, and a sheet-level
  // setState at that rate rebuilt the entire detail view — every transcript
  // line — per tick. Only the slider row listens to these.
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _duration = ValueNotifier(Duration.zero);

  // Inline title editing
  bool _isEditingTitle = false;
  final TextEditingController _titleController = TextEditingController();
  final FocusNode _titleFocusNode = FocusNode();

  // Monotonic guard for _selectSession: its timestamp parse is async, so a
  // second tap during the parse starts a second flight — only the latest
  // tap's result may land (completion order isn't tap order).
  int _selectEpoch = 0;

  @override
  void initState() {
    super.initState();
    _initPlayer();
    if (widget.initialSessionId != null) {
      _loadInitialSession(widget.initialSessionId!);
    }
    _syncFromServer();
    _titleFocusNode.addListener(_onTitleFocusChanged);
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
      if (!mounted) return;
      _position.value = event.position;
      if (event.duration > Duration.zero) {
        _duration.value = event.duration;
      }
    });
    _playerInitialized = true;
  }

  @override
  void dispose() {
    _titleFocusNode.removeListener(_onTitleFocusChanged);
    _titleFocusNode.dispose();
    _titleController.dispose();
    _position.dispose();
    _duration.dispose();
    if (_playerInitialized) {
      _player.closePlayer();
    }
    super.dispose();
  }

  void _selectSession(TranscriptSession session) async {
    final epoch = ++_selectEpoch;
    // Stop any playing audio when switching
    if (_isPlaying) {
      await _player.stopPlayer();
    }
    // Parse word timestamps off the UI isolate if available
    List<List<WordTimestamp>>? timestamps;
    if (session.timestampsJson != null) {
      try {
        timestamps =
            await compute(_parseTimestampsJson, session.timestampsJson!);
      } catch (_) {}
    }
    if (!mounted || epoch != _selectEpoch) return;
    setState(() {
      _selectedSession = session;
      _parsedTimestamps = timestamps;
      _isPlaying = false;
    });
    _position.value = Duration.zero;
    _duration.value = Duration.zero;
    // Calculate duration from file
    if (session.audioPath != null) {
      final file = File(session.audioPath!);
      if (await file.exists()) {
        final fileSize = await file.length();
        final dataSize = fileSize - 44;
        final bytesPerSecond =
            AppConstants.sampleRate * AppConstants.numChannels * 2;
        final durationSecs = dataSize / bytesPerSecond;
        if (mounted && epoch == _selectEpoch) {
          _duration.value =
              Duration(milliseconds: (durationSecs * 1000).round());
        }
      }
    }
  }

  void _goBackToList() async {
    if (_isPlaying) {
      await _player.stopPlayer();
    }
    if (!mounted) return;
    setState(() {
      _selectedSession = null;
      _parsedTimestamps = null;
      _isPlaying = false;
      _isEditingTitle = false;
    });
    _position.value = Duration.zero;
    _duration.value = Duration.zero;
  }

  void _startEditingTitle() {
    final currentTitle =
        _selectedSession?.title ?? _formatDate(_selectedSession!.createdAt);
    _titleController.text = currentTitle;
    setState(() => _isEditingTitle = true);
    // Request focus after the frame so the TextField is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _titleFocusNode.requestFocus();
    });
  }

  void _onTitleFocusChanged() {
    if (!_titleFocusNode.hasFocus && _isEditingTitle) {
      _saveTitle();
    }
  }

  Future<void> _saveTitle() async {
    if (!_isEditingTitle || _selectedSession == null) return;
    final newTitle = _titleController.text.trim();
    if (newTitle.isEmpty) {
      setState(() => _isEditingTitle = false);
      return;
    }
    final id = _selectedSession!.id;
    if (id != null) {
      await DatabaseService.instance.updateSessionTitle(id, newTitle);
      // Reload the session to get updated data
      final updated = await DatabaseService.instance.getSession(id);
      if (updated != null && mounted) {
        setState(() {
          _selectedSession = updated;
          _isEditingTitle = false;
        });
        ref.invalidate(sessionHistoryProvider);
      }
    } else {
      setState(() => _isEditingTitle = false);
    }
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
        final seekTarget =
            _position.value > Duration.zero ? _position.value : null;
        setState(() => _isPlaying = true);
        await _player.startPlayer(
          fromURI: audioPath,
          codec: Codec.pcm16WAV,
          whenFinished: () {
            if (mounted) {
              setState(() => _isPlaying = false);
              _position.value = Duration.zero;
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
    final newPos = _position.value + Duration(seconds: seconds);
    final clamped = newPos < Duration.zero
        ? Duration.zero
        : (newPos > _duration.value ? _duration.value : newPos);
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
      _position.value = target;
    } else {
      // Stopped — just update position visually; will seek on next play
      _position.value = target;
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
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(audioPath, mimeType: 'audio/wav')],
        subject: 'Silsigan Audio — $date',
        sharePositionOrigin:
            box != null ? box.localToGlobal(Offset.zero) & box.size : null,
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
      UserService.instance.reportActivity('session_delete');
      ref.invalidate(sessionHistoryProvider);
      _goBackToList();
    }
  }

  Future<void> _sendToNotes() async {
    if (_selectedSession == null) return;
    try {
      final session = _selectedSession!;
      final date = _formatDate(session.createdAt);
      final sessionTitle = session.title ?? date;
      final text = StringBuffer();
      text.writeln('$sessionTitle — $date');
      text.writeln();
      text.writeln('── TRANSCRIPTION ──');
      text.writeln(session.koreanFull);
      if (session.vietnameseFull.trim().isNotEmpty) {
        text.writeln();
        text.writeln('── TRANSLATION ──');
        text.writeln(session.vietnameseFull);
      }

      final box = context.findRenderObject() as RenderBox?;
      await Share.share(
        text.toString(),
        subject: sessionTitle,
        sharePositionOrigin:
            box != null ? box.localToGlobal(Offset.zero) & box.size : null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
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
              Text(
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
    final hasTranslation = session.vietnameseFull.trim().isNotEmpty;

    return Column(
      key: const ValueKey('history-detail'),
      children: [
        _buildDragHandle(),
        // Header with back, title, download, delete
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
                child: _isEditingTitle
                    ? TextField(
                        controller: _titleController,
                        focusNode: _titleFocusNode,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppConstants.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 4),
                          border: InputBorder.none,
                        ),
                        onSubmitted: (_) => _saveTitle(),
                      )
                    : GestureDetector(
                        onTap: _startEditingTitle,
                        child: Text(
                          session.title ?? _formatDate(session.createdAt),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppConstants.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
              ),
              IconButton(
                icon: const Icon(Icons.note_add_outlined),
                color: AppConstants.textSecondary,
                iconSize: 22,
                onPressed: _sendToNotes,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: _deleteSession,
              ),
            ],
          ),
        ),
        // Content — lazy slivers: only rows near the viewport are built,
        // laid out, and painted. The old SingleChildScrollView materialized
        // every line of the session up front and repainted them all on each
        // scroll frame, which visibly janked on multi-thousand-word
        // transcripts.
        Expanded(
          child: SelectionArea(
            child: CustomScrollView(
              controller: scrollController,
              slivers: [
                ..._buildTextBoxSlivers(
                  label: 'TRANSCRIPTION',
                  lines: koreanLines,
                  fullText: session.koreanFull,
                  timestamps: hasAudio ? _parsedTimestamps : null,
                ),
                if (hasTranslation) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 5)),
                  ..._buildTextBoxSlivers(
                    label: 'TRANSLATION',
                    lines: vietnameseLines,
                    fullText: session.vietnameseFull,
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
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
    return Container(
      color: AppConstants.panelColor,
      padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Only this slider row listens to the 10Hz progress stream — the
          // rest of the sheet (and the transcript list above) never rebuilds
          // for a playback tick.
          ListenableBuilder(
            listenable: Listenable.merge([_position, _duration]),
            builder: (context, _) {
              final progress = _duration.value.inMilliseconds > 0
                  ? _position.value.inMilliseconds /
                      _duration.value.inMilliseconds
                  : 0.0;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: AppConstants.textPrimary,
                      inactiveTrackColor:
                          AppConstants.textPrimary.withOpacity(0.2),
                      thumbColor: AppConstants.textPrimary,
                    ),
                    child: Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChanged: (value) {
                        final newPos = Duration(
                          milliseconds:
                              (value * _duration.value.inMilliseconds).round(),
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
                          _formatDuration(_position.value),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppConstants.textSecondary.withOpacity(0.7),
                          ),
                        ),
                        Text(
                          _formatDuration(_duration.value),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppConstants.textSecondary.withOpacity(0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
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
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppConstants.textPrimary,
                        ),
                        child: Icon(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                          size: 30,
                          // Pairs with the textPrimary circle, which inverts
                          // in dark mode.
                          color: AppConstants.micIconColor,
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

  /// One text box (label + lines) as lazy slivers. Visually identical to the
  /// old solid Container box: DecoratedSliver paints the panel background and
  /// rounded corners as one continuous decoration behind the lazily-built
  /// rows, SliverPadding reproduces the box's inner padding, and each line
  /// keeps its old bottom-8 spacing.
  List<Widget> _buildTextBoxSlivers({
    required String label,
    required List<String> lines,
    required String fullText,
    List<List<WordTimestamp>>? timestamps,
  }) {
    final hasText = fullText.trim().isNotEmpty;
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: DecoratedSliver(
          decoration: BoxDecoration(
            color: AppConstants.panelColor,
            borderRadius: BorderRadius.circular(AppConstants.panelBorderRadius),
          ),
          sliver: SliverPadding(
            padding: const EdgeInsets.all(AppConstants.panelPaddingH),
            sliver: SliverList.builder(
              // Row 0 is the label row, row 1 the gap below it, then lines.
              itemCount: lines.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
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
                          child: Icon(
                            Icons.copy,
                            size: 18,
                            color: AppConstants.textSecondary,
                          ),
                        ),
                    ],
                  );
                }
                if (index == 1) return const SizedBox(height: 12);

                final lineIdx = index - 2;
                final line = lines[lineIdx];
                final words = (timestamps != null &&
                        lineIdx < timestamps.length &&
                        timestamps[lineIdx].isNotEmpty)
                    ? timestamps[lineIdx]
                    : null;

                // Align start, not stretch: sliver rows span the full width,
                // but the old Column start-aligned each line at its intrinsic
                // width — this keeps short RTL lines on the left edge exactly
                // as before.
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: words != null
                        ? _TappableTimestampLine(
                            line: line,
                            words: words,
                            onSeek: _seekToMs,
                          )
                        : Text(
                            line,
                            textDirection: directionOf(line),
                            style: TextStyle(
                              fontSize: AppConstants.contentFontSize,
                              color: AppConstants.textPrimary,
                              height: 1.5,
                            ),
                          ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ];
  }
}

/// One saved-session line with per-word tap-to-seek spans.
///
/// Owns its gesture recognizers and its transient tap-highlight. The old
/// sheet-level version rebuilt every recognizer for every word of the session
/// on any sheet rebuild (accumulating the stale ones in a list that was only
/// cleared on session switch — thousands per second during playback ticks),
/// and a single word-tap highlight rebuilt the entire transcript. Localizing
/// both keeps a multi-thousand-word session smooth.
class _TappableTimestampLine extends StatefulWidget {
  final String line;
  final List<WordTimestamp> words;

  /// Called with the tapped word's start offset in milliseconds.
  final ValueChanged<int> onSeek;

  const _TappableTimestampLine({
    required this.line,
    required this.words,
    required this.onSeek,
  });

  @override
  State<_TappableTimestampLine> createState() => _TappableTimestampLineState();
}

/// A matched word: the plain text preceding it, the tappable token itself,
/// and the recognizer created once for the line's lifetime.
class _WordSegment {
  final String plainBefore;
  final String token;
  final int wordIdx;
  final TapGestureRecognizer recognizer;

  _WordSegment(this.plainBefore, this.token, this.wordIdx, this.recognizer);
}

class _TappableTimestampLineState extends State<_TappableTimestampLine> {
  final List<_WordSegment> _segments = [];
  String _trailing = '';
  int? _highlightedWordIdx;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    _computeSegments();
  }

  @override
  void didUpdateWidget(_TappableTimestampLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A recycled list element can be handed a different line (e.g. switching
    // sessions) — recompute the segment cache for the new content.
    if (widget.line != oldWidget.line ||
        !identical(widget.words, oldWidget.words)) {
      _disposeSegments();
      _computeSegments();
      _highlightTimer?.cancel();
      _highlightedWordIdx = null;
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _disposeSegments();
    super.dispose();
  }

  void _disposeSegments() {
    for (final s in _segments) {
      s.recognizer.dispose();
    }
    _segments.clear();
  }

  /// Words are matched sequentially: walk through the line text finding each
  /// timestamp token, making matched portions tappable and gaps plain text.
  void _computeSegments() {
    final line = widget.line;
    int cursor = 0;
    int wordIdx = 0;
    for (final wt in widget.words) {
      final token = wt.text;
      if (token.isEmpty) continue;

      // Find this token in the remaining line text
      final idx = line.indexOf(token, cursor);
      if (idx < 0) continue;

      final currentWordIdx = wordIdx;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _onWordTap(currentWordIdx, wt.startMs);
      _segments.add(_WordSegment(
        idx > cursor ? line.substring(cursor, idx) : '',
        token,
        currentWordIdx,
        recognizer,
      ));

      cursor = idx + token.length;
      wordIdx++;
    }
    _trailing = cursor < line.length ? line.substring(cursor) : '';
  }

  void _onWordTap(int wordIdx, int startMs) {
    HapticFeedback.selectionClick();
    widget.onSeek(startMs);
    // Flash highlight — local to this line only.
    setState(() => _highlightedWordIdx = wordIdx);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _highlightedWordIdx = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = TextStyle(
      fontSize: AppConstants.contentFontSize,
      color: AppConstants.textPrimary,
      height: 1.5,
    );

    final highlightStyle = TextStyle(
      fontSize: AppConstants.contentFontSize,
      color: AppConstants.textPrimary,
      height: 1.5,
      backgroundColor: AppConstants.isDark
          ? const Color(0x30FFFFFF)
          : const Color(0x30000000),
    );

    final spans = <InlineSpan>[];
    for (final s in _segments) {
      if (s.plainBefore.isNotEmpty) {
        spans.add(TextSpan(text: s.plainBefore, style: baseStyle));
      }
      spans.add(TextSpan(
        text: s.token,
        style: s.wordIdx == _highlightedWordIdx ? highlightStyle : baseStyle,
        recognizer: s.recognizer,
      ));
    }
    if (_trailing.isNotEmpty) {
      spans.add(TextSpan(text: _trailing, style: baseStyle));
    }

    return Text.rich(
      TextSpan(children: spans),
      textDirection: directionOf(widget.line),
    );
  }
}
