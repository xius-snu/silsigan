import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/transcript_session.dart';
import '../../models/word_timestamp.dart';
import '../../providers/account_provider.dart';
import '../../providers/session_history_provider.dart';
import '../../services/database_service.dart';
import '../../services/session_audio_files.dart';
import '../../services/session_audio_player.dart';
import '../../services/sync_service.dart';
import '../../services/user_service.dart';
import '../../utils/constants.dart';
import '../../utils/text_direction_utils.dart';
import '../../utils/word_timeline.dart';
import 'account_sheet.dart';
import 'session_card.dart';

/// Isolate entry: a saved session's word timestamps (`args[0]`, JSON) on the
/// recording's timeline and matched to its transcript as it reads now
/// (`args[1]`). Returns per transcript line the spans [alignWordSpans]
/// describes. The JSON carries one entry per word, so a long session decoded
/// inline janked the open animation.
List<List<int>> _wordSpansFor(List<String> args) {
  final raw = jsonDecode(args[0]) as List;
  final words = raw
      .map((line) => (line as List)
          .map((w) => WordTimestamp.fromJson(w as Map<String, dynamic>))
          .toList())
      .toList();
  return alignWordSpans(
    args[1].split('\n'),
    wordsOnRecordingTimeline(words),
  );
}

enum _SessionTextField { transcription, translation }

String _previewOf(String full) {
  if (full.length > AppConstants.previewMaxLength) {
    return full.substring(0, AppConstants.previewMaxLength);
  }
  return full;
}

class HistorySheet extends ConsumerStatefulWidget {
  final double maxFraction;
  final int? initialSessionId;

  /// Main screen still owns usage figures; after the account sheet closes we
  /// ask it to re-fetch, matching the old header control.
  final VoidCallback? onAccountSheetClosed;

  const HistorySheet({
    super.key,
    required this.maxFraction,
    this.initialSessionId,
    this.onAccountSheetClosed,
  });

  @override
  ConsumerState<HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends ConsumerState<HistorySheet> {
  TranscriptSession? _selectedSession;

  // Audio player
  final SessionAudioPlayer _player = SessionAudioPlayer();
  bool _playerInitialized = false;

  /// The selected session's recording as it is found now (see
  /// [SessionAudioFiles]); null when it has none or it isn't on this device.
  String? _audioFile;

  // Bumped whenever playback stops or the selection changes, so a start
  // still in flight can't play over the next session.
  int _playbackEpoch = 0;

  // Tap-to-seek spans per transcription line (see alignWordSpans), for the
  // transcription text in [_wordSpansText]. An edit re-matches them.
  List<List<int>>? _wordSpans;
  String? _wordSpansText;
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

  // Inline transcription / translation editing (opt-in; default read-only)
  _SessionTextField? _editingBox;
  final TextEditingController _textEditController = TextEditingController();
  final FocusNode _textEditFocusNode = FocusNode();

  // Monotonic guard for _selectSession: its timestamp parse is async, so a
  // second tap during the parse starts a second flight — only the latest
  // tap's result may land (completion order isn't tap order).
  int _selectEpoch = 0;

  /// Sheet scroll controller from [DraggableScrollableSheet]; used to jump
  /// to the start of the transcript when edit mode opens.
  ScrollController? _sheetScroll;

  /// True after the user has scrolled to the bottom of the saved session.
  /// A jump-to-top control then stays up until they return to the top.
  bool _reachedTranscriptBottom = false;
  bool _showJumpToTop = false;

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

  /// Same post-close refresh the main-screen header used: history here, usage
  /// via [onAccountSheetClosed]. AccountService's listener on MainScreen also
  /// fires on a real sign-in/out.
  Future<void> _openAccountSheet() async {
    await showAccountSheet(context);
    if (!mounted) return;
    ref.invalidate(sessionHistoryProvider);
    widget.onAccountSheetClosed?.call();
  }

  Future<void> _loadInitialSession(int id) async {
    final session = await DatabaseService.instance.getSession(id);
    if (session != null && mounted) {
      _selectSession(session);
    }
  }

  Future<void> _initPlayer() async {
    try {
      await _player.openPlayer(
        onProgress: (position, duration) {
          if (!mounted) return;
          _position.value = position;
          if (duration > Duration.zero) {
            _duration.value = duration;
          }
        },
      );
      _playerInitialized = true;
    } catch (e) {
      debugPrint('Session audio player init failed: $e');
    }
  }

  @override
  void dispose() {
    _titleFocusNode.removeListener(_onTitleFocusChanged);
    final pending = _captureTextEdit();
    _titleFocusNode.dispose();
    _titleController.dispose();
    _textEditFocusNode.dispose();
    _textEditController.dispose();
    _position.dispose();
    _duration.dispose();
    if (pending != null) {
      unawaited(_persistTextEdit(pending, updateUi: false));
    }
    if (_playerInitialized) {
      _player.closePlayer();
    }
    super.dispose();
  }

  void _selectSession(TranscriptSession session) async {
    final epoch = ++_selectEpoch;
    // Stop the previous recording even when it's only paused: a paused
    // player used to be resumed by this session's play button, playing the
    // other recording from where it was left.
    await _stopPlayback();
    // Always re-read from SQLite so a just-saved edit (or a cloud pull
    // that landed while the list was cached) is what we display.
    if (session.id != null) {
      final fresh = await DatabaseService.instance.getSession(session.id!);
      if (fresh != null) session = fresh;
    }
    if (!mounted || epoch != _selectEpoch) return;
    final audioFile = await SessionAudioFiles.resolve(session.audioPath);
    var duration = Duration.zero;
    if (audioFile != null) {
      try {
        // Duration from the file size: 44-byte header, then PCM16.
        final dataSize = await File(audioFile).length() - 44;
        const bytesPerSecond =
            AppConstants.sampleRate * AppConstants.numChannels * 2;
        duration = Duration(
          milliseconds: (dataSize / bytesPerSecond * 1000).round(),
        );
      } catch (_) {}
    }
    // Word spans off the UI isolate; only a recording on this device gives
    // a tap somewhere to seek to.
    List<List<int>>? spans;
    if (audioFile != null && session.timestampsJson != null) {
      try {
        spans = await compute(
          _wordSpansFor,
          [session.timestampsJson!, session.koreanFull],
        );
      } catch (_) {}
    }
    if (!mounted || epoch != _selectEpoch) return;
    setState(() {
      _selectedSession = session;
      _audioFile = audioFile;
      _wordSpans = spans;
      _wordSpansText = spans == null ? null : session.koreanFull;
      _isPlaying = false;
      _editingBox = null;
      _reachedTranscriptBottom = false;
      _showJumpToTop = false;
    });
    _position.value = Duration.zero;
    _duration.value = duration > Duration.zero ? duration : Duration.zero;
  }

  void _goBackToList() async {
    await _saveTextEdit();
    await _stopPlayback();
    if (!mounted) return;
    setState(() {
      _selectedSession = null;
      _audioFile = null;
      _wordSpans = null;
      _wordSpansText = null;
      _isPlaying = false;
      _isEditingTitle = false;
      _editingBox = null;
      _reachedTranscriptBottom = false;
      _showJumpToTop = false;
    });
    _position.value = Duration.zero;
    _duration.value = Duration.zero;
  }

  /// Stops playback, paused included, and drops the loaded recording.
  /// Callers reset [_isPlaying] in their own setState.
  Future<void> _stopPlayback() async {
    _playbackEpoch++;
    if (!_playerInitialized) return;
    if (!_isPlaying && !_player.isPaused && _player.loadedPath == null) return;
    try {
      await _player.stopPlayer().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Re-matches tap-to-seek spans after the transcription text was edited.
  Future<void> _refreshWordSpans() async {
    final session = _selectedSession;
    final json = session?.timestampsJson;
    if (session == null || json == null || _audioFile == null) return;
    final text = session.koreanFull;
    if (text == _wordSpansText) return;
    final epoch = _selectEpoch;
    List<List<int>>? spans;
    try {
      spans = await compute(_wordSpansFor, [json, text]);
    } catch (_) {}
    if (!mounted || epoch != _selectEpoch) return;
    // Edited again while matching: that edit's own refresh lands instead.
    if (_selectedSession?.koreanFull != text) return;
    setState(() {
      _wordSpans = spans;
      _wordSpansText = text;
    });
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
      final updated = await DatabaseService.instance.getSession(id);
      if (updated != null && mounted) {
        setState(() {
          _selectedSession = updated;
          _isEditingTitle = false;
        });
        ref.invalidate(sessionHistoryProvider);
        unawaited(SyncService.instance.uploadSession(updated));
      }
    } else {
      setState(() => _isEditingTitle = false);
    }
  }

  void _startEditingText(_SessionTextField field) {
    if (_selectedSession == null) return;
    if (_editingBox == field) return;
    _PendingTextEdit? pending;
    if (_editingBox != null) {
      pending = _captureTextEdit();
    }
    final session = _selectedSession!;
    _textEditController.text = field == _SessionTextField.transcription
        ? session.koreanFull
        : session.vietnameseFull;
    setState(() => _editingBox = field);
    if (pending != null) {
      unawaited(_persistTextEdit(pending, updateUi: true));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingBox != field) return;
      if (_sheetScroll?.hasClients == true) {
        _sheetScroll!.jumpTo(0);
      }
      _textEditController.selection = const TextSelection.collapsed(offset: 0);
      _textEditFocusNode.requestFocus();
      if (_reachedTranscriptBottom || _showJumpToTop) {
        setState(() {
          _reachedTranscriptBottom = false;
          _showJumpToTop = false;
        });
      }
    });
  }

  /// Snapshot the in-progress edit and clear [_editingBox]. Callers must
  /// [setState] if the widget is still mounted. Returns null when there is
  /// nothing to persist (not editing, or text unchanged).
  _PendingTextEdit? _captureTextEdit() {
    if (_editingBox == null || _selectedSession == null) return null;
    final id = _selectedSession!.id;
    final box = _editingBox!;
    final newText = _textEditController.text;
    final session = _selectedSession!;
    _editingBox = null;
    if (id == null) return null;

    final unchanged = box == _SessionTextField.transcription
        ? newText == session.koreanFull
        : newText == session.vietnameseFull;
    if (unchanged) return null;

    // Keep the in-memory row current so a follow-up edit of the other
    // box (or a concurrent persist) cannot read stale sibling text.
    _selectedSession = box == _SessionTextField.transcription
        ? session.copyWith(
            koreanFull: newText,
            koreanPreview: _previewOf(newText),
          )
        : session.copyWith(
            vietnameseFull: newText,
            vietnamesePreview: _previewOf(newText),
          );

    return _PendingTextEdit(id: id, field: box, text: newText);
  }

  void _onTranscriptScroll(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return;
    final extent = metrics.maxScrollExtent;
    if (extent <= 80) {
      if (_reachedTranscriptBottom || _showJumpToTop) {
        setState(() {
          _reachedTranscriptBottom = false;
          _showJumpToTop = false;
        });
      }
      return;
    }
    final atTop = metrics.pixels <= 48;
    final atBottom = metrics.pixels >= extent - 48;
    var reached = _reachedTranscriptBottom;
    var show = _showJumpToTop;
    if (atBottom) reached = true;
    if (atTop) {
      reached = false;
      show = false;
    } else if (reached) {
      show = true;
    }
    if (reached != _reachedTranscriptBottom || show != _showJumpToTop) {
      setState(() {
        _reachedTranscriptBottom = reached;
        _showJumpToTop = show;
      });
    }
  }

  void _jumpToTranscriptTop() {
    final c = _sheetScroll;
    if (c != null && c.hasClients) {
      c.animateTo(
        0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
    if (_reachedTranscriptBottom || _showJumpToTop) {
      setState(() {
        _reachedTranscriptBottom = false;
        _showJumpToTop = false;
      });
    }
  }

  Future<void> _saveTextEdit() async {
    if (_editingBox == null) return;
    final pending = _captureTextEdit();
    if (mounted) setState(() {});
    if (_textEditFocusNode.hasFocus) {
      _textEditFocusNode.unfocus();
    }
    if (pending == null) return;
    await _persistTextEdit(pending, updateUi: true);
  }

  Future<void> _persistTextEdit(
    _PendingTextEdit pending, {
    required bool updateUi,
  }) async {
    if (updateUi && pending.field == _SessionTextField.transcription) {
      unawaited(_refreshWordSpans());
    }
    await DatabaseService.instance.updateSessionText(
      id: pending.id,
      koreanFull: pending.field == _SessionTextField.transcription
          ? pending.text
          : null,
      vietnameseFull:
          pending.field == _SessionTextField.translation ? pending.text : null,
      koreanPreview: pending.field == _SessionTextField.transcription
          ? _previewOf(pending.text)
          : null,
      vietnamesePreview: pending.field == _SessionTextField.translation
          ? _previewOf(pending.text)
          : null,
    );
    final updated = await DatabaseService.instance.getSession(pending.id);
    if (updated == null) return;
    unawaited(SyncService.instance.uploadSession(updated));
    if (!updateUi || !mounted) return;
    // Don't replace the in-memory row while the other box is being
    // edited — capture already applied this field locally.
    if (_editingBox == null) {
      setState(() => _selectedSession = updated);
    }
    ref.invalidate(sessionHistoryProvider);
  }

  /// Whether the player holds the selected session's recording (playing or
  /// paused), as opposed to nothing or another session's.
  bool get _playerHoldsSelected =>
      _audioFile != null && _player.loadedPath == _audioFile;

  Future<void> _playPause() async {
    if (!_playerInitialized) return;
    final audioPath = _audioFile;
    if (audioPath == null) return;
    final epoch = _playbackEpoch;

    try {
      if (_isPlaying) {
        await _player.pausePlayer();
        if (mounted) setState(() => _isPlaying = false);
      } else if (_player.isPaused && _playerHoldsSelected) {
        await _player.resumePlayer();
        if (mounted) setState(() => _isPlaying = true);
      } else {
        if (!await File(audioPath).exists()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Audio file not found')),
            );
          }
          return;
        }
        if (epoch != _playbackEpoch) return;
        final seekTarget =
            _position.value > Duration.zero ? _position.value : null;
        if (mounted) setState(() => _isPlaying = true);
        await _player.startPlayer(
          fromURI: audioPath,
          codec: Codec.pcm16WAV,
          whenFinished: () {
            if (mounted && epoch == _playbackEpoch) {
              setState(() => _isPlaying = false);
              _position.value = Duration.zero;
            }
          },
        );
        // Back or another session while the player was starting.
        if (epoch != _playbackEpoch) {
          if (_player.loadedPath == audioPath) await _player.stopPlayer();
          return;
        }
        // If user tapped a word before playing, seek to that position
        if (seekTarget != null) {
          await Future.delayed(const Duration(milliseconds: 50));
          await _player.seekToPlayer(seekTarget);
        }
      }
    } catch (_) {
      try {
        await _player.stopPlayer();
      } catch (_) {}
      if (!mounted) return;
      setState(() => _isPlaying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't play this recording")),
      );
    }
  }

  Future<void> _seekRelative(int seconds) async {
    if (!_playerInitialized || !_playerHoldsSelected) return;
    if (!_isPlaying && !_player.isPaused) return;
    final newPos = _position.value + Duration(seconds: seconds);
    final clamped = newPos < Duration.zero
        ? Duration.zero
        : (newPos > _duration.value ? _duration.value : newPos);
    await _player.seekToPlayer(clamped);
  }

  Future<void> _seekTo(Duration position) async {
    if (!_playerInitialized || !_playerHoldsSelected) return;
    if (!_isPlaying && !_player.isPaused) return;
    await _player.seekToPlayer(position);
  }

  /// Seek audio to [ms] milliseconds.
  /// - If playing: seek and continue playing.
  /// - If paused or stopped: just update position visually (no auto-play).
  Future<void> _seekToMs(int ms) async {
    if (!_playerInitialized || _audioFile == null) return;

    var target = Duration(milliseconds: ms);
    final duration = _duration.value;
    if (duration > Duration.zero && target > duration) target = duration;

    if (_isPlaying && _playerHoldsSelected) {
      // Currently playing — seek and continue
      await _player.seekToPlayer(target);
    } else if (_player.isPaused && _playerHoldsSelected) {
      // Paused — seek but stay paused, update UI
      await _player.seekToPlayer(target);
      _position.value = target;
    } else {
      // Stopped — just update position visually; will seek on next play
      _position.value = target;
    }
  }

  Future<void> _shareAudio() async {
    final audioPath = _audioFile;
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
      // Paused counts too: the Windows player keeps the WAV open, and an
      // open file can't be deleted there.
      await _stopPlayback();
      final createdAt = _selectedSession!.createdAt;
      await DatabaseService.instance.deleteSession(_selectedSession!.id!);
      unawaited(SyncService.instance.deleteFromServer(createdAt).then((ok) {
        if (ok) {
          return DatabaseService.instance.markTombstonesSynced([createdAt]);
        }
      }).catchError((_) {}));
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

  /// Android's system nav bar (3-button or gesture pill) sits under sheet
  /// content; modal routes are not inside the scaffold SafeArea. iOS's home
  /// indicator doesn't collide the same way. viewPadding stays correct if a
  /// keyboard is up, unlike padding.bottom which is consumed.
  double get _androidNavInset =>
      Platform.isAndroid ? MediaQuery.of(context).viewPadding.bottom : 0.0;

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: DraggableScrollableSheet(
        initialChildSize: widget.maxFraction,
        minChildSize: 0.4,
        maxChildSize: widget.maxFraction,
        expand: false,
        builder: (context, scrollController) {
          _sheetScroll = scrollController;
          return PopScope(
            canPop: _selectedSession == null,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop || _selectedSession == null) return;
              // Android Back while editing: save and leave edit mode.
              // The next Back (no longer editing) returns to the list.
              if (_editingBox != null) {
                _saveTextEdit();
                return;
              }
              _goBackToList();
            },
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _selectedSession == null
                  ? _buildListView(scrollController)
                  : _buildDetailView(scrollController),
            ),
          );
        },
      ),
    );
  }

  Widget _buildListView(ScrollController scrollController) {
    final sessionsAsync = ref.watch(sessionHistoryProvider);
    return Column(
      key: const ValueKey('history-list'),
      children: [
        _buildDragHandle(),
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 4, bottom: 8),
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
              const Spacer(),
              _buildAccountIcon(),
            ],
          ),
        ),
        Expanded(
          child: sessionsAsync.when(
            skipLoadingOnReload: true,
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
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: 8 + _androidNavInset,
                ),
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
    final hasAudio = _audioFile != null;
    // Recorded with audio, but the file is no longer on this device.
    final audioMissing = !hasAudio && session.audioPath != null;
    final hasTranslation = session.vietnameseFull.trim().isNotEmpty;
    // Spans matched to an older text would point at the wrong words.
    final wordSpans =
        hasAudio && _wordSpansText == session.koreanFull ? _wordSpans : null;

    return Column(
      key: const ValueKey('history-detail'),
      children: [
        // Chrome above the transcript panel: tap here (or Back) to leave
        // edit mode. Taps/scrolls inside the panel must not.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_editingBox != null) _saveTextEdit();
          },
          child: Column(
            children: [
              _buildDragHandle(),
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
                                contentPadding:
                                    EdgeInsets.symmetric(vertical: 4),
                                border: InputBorder.none,
                              ),
                              onSubmitted: (_) => _saveTitle(),
                            )
                          : GestureDetector(
                              onTap: () {
                                if (_editingBox != null) {
                                  unawaited(_saveTextEdit());
                                }
                                _startEditingTitle();
                              },
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
                      onPressed: () {
                        if (_editingBox != null) unawaited(_saveTextEdit());
                        _sendToNotes();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () {
                        if (_editingBox != null) unawaited(_saveTextEdit());
                        _deleteSession();
                      },
                    ),
                  ],
                ),
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
          child: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  _onTranscriptScroll(n.metrics);
                  return false;
                },
                child: SelectionArea(
                  child: CustomScrollView(
                    controller: scrollController,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    slivers: [
                      ..._buildTextBoxSlivers(
                        field: _SessionTextField.transcription,
                        label: 'TRANSCRIPTION',
                        lines: koreanLines,
                        fullText: session.koreanFull,
                        wordSpans: wordSpans,
                      ),
                      if (hasTranslation) ...[
                        const SliverToBoxAdapter(child: SizedBox(height: 5)),
                        ..._buildTextBoxSlivers(
                          field: _SessionTextField.translation,
                          label: 'TRANSLATION',
                          lines: vietnameseLines,
                          fullText: session.vietnameseFull,
                        ),
                      ],
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 16 +
                              (hasAudio || audioMissing ? 0 : _androidNavInset),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showJumpToTop)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Material(
                      color: AppConstants.panelColor,
                      elevation: 3,
                      shadowColor: Colors.black26,
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Jump to top',
                        icon: Icon(
                          Icons.keyboard_arrow_up_rounded,
                          color: AppConstants.textPrimary,
                        ),
                        onPressed: _jumpToTranscriptTop,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // Audio player
        if (hasAudio)
          _buildAudioPlayer()
        else if (audioMissing)
          _buildMissingAudioNote(),
      ],
    );
  }

  /// In place of the player when the recording isn't on this device (the
  /// app was deleted and reinstalled, say), instead of a 00:00 player whose
  /// button does nothing.
  Widget _buildMissingAudioNote() {
    return Container(
      width: double.infinity,
      color: AppConstants.panelColor,
      padding: EdgeInsets.only(
          left: 20, right: 20, top: 14, bottom: 18 + _androidNavInset),
      child: Row(
        children: [
          Icon(
            Icons.music_off_outlined,
            size: 20,
            color: AppConstants.textSecondary.withOpacity(0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "This session's audio isn't on this device.",
              style: TextStyle(
                fontSize: 13,
                color: AppConstants.textSecondary.withOpacity(0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountIcon() {
    final linked = ref.watch(accountProvider).linked;
    return IconButton(
      icon: Icon(linked ? Icons.person : Icons.person_outline),
      iconSize: 22,
      color: linked ? AppConstants.textPrimary : AppConstants.textSecondary,
      tooltip: 'Account',
      visualDensity: VisualDensity.compact,
      onPressed: _openAccountSheet,
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
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 12, bottom: 24 + _androidNavInset),
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
    required _SessionTextField field,
    required String label,
    required List<String> lines,
    required String fullText,
    List<List<int>>? wordSpans,
  }) {
    final hasText = fullText.trim().isNotEmpty;
    final isEditing = _editingBox == field;
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
              // Row 0 is the label row, row 1 the gap below it, then lines
              // (or a single TextField while editing).
              itemCount: isEditing ? 3 : lines.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _buildTextBoxHeader(
                    field: field,
                    label: label,
                    fullText: fullText,
                    hasText: hasText,
                    isEditing: isEditing,
                  );
                }
                if (index == 1) return const SizedBox(height: 12);

                if (isEditing) {
                  return SelectionContainer.disabled(
                    child: TextField(
                      controller: _textEditController,
                      focusNode: _textEditFocusNode,
                      maxLines: null,
                      minLines: 1,
                      scrollPhysics: const NeverScrollableScrollPhysics(),
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textDirection: directionOf(_textEditController.text),
                      style: TextStyle(
                        fontSize: AppConstants.contentFontSize,
                        color: AppConstants.textPrimary,
                        height: 1.5,
                      ),
                      cursorColor: AppConstants.textPrimary,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  );
                }

                final lineIdx = index - 2;
                final line = lines[lineIdx];
                final spans = (wordSpans != null &&
                        lineIdx < wordSpans.length &&
                        wordSpans[lineIdx].isNotEmpty)
                    ? wordSpans[lineIdx]
                    : null;

                // Align start, not stretch: sliver rows span the full width,
                // but the old Column start-aligned each line at its intrinsic
                // width — this keeps short RTL lines on the left edge exactly
                // as before.
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: spans != null
                        ? _TappableTimestampLine(
                            line: line,
                            spans: spans,
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

  Widget _buildTextBoxHeader({
    required _SessionTextField field,
    required String label,
    required String fullText,
    required bool hasText,
    required bool isEditing,
  }) {
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () {
            if (isEditing) {
              _saveTextEdit();
            } else {
              _startEditingText(field);
            }
          },
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              isEditing ? Icons.check : Icons.edit_outlined,
              size: 18,
              color: isEditing
                  ? AppConstants.textPrimary
                  : AppConstants.textSecondary,
            ),
          ),
        ),
        if (hasText || isEditing) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              final text = isEditing ? _textEditController.text : fullText;
              if (text.trim().isEmpty) return;
              _copyText(text, label);
            },
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.copy,
                size: 18,
                color: AppConstants.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );

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
        if (isEditing) TextFieldTapRegion(child: actions) else actions,
      ],
    );
  }
}

class _PendingTextEdit {
  const _PendingTextEdit({
    required this.id,
    required this.field,
    required this.text,
  });

  final int id;
  final _SessionTextField field;
  final String text;
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

  /// Flat `[start, end, ms]` triples from [alignWordSpans]: the characters of
  /// [line] a word covers and where it starts in the recording.
  final List<int> spans;

  /// Called with the tapped word's start offset in milliseconds.
  final ValueChanged<int> onSeek;

  const _TappableTimestampLine({
    required this.line,
    required this.spans,
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
        !identical(widget.spans, oldWidget.spans)) {
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

  /// Matched words become tappable; the text between them stays plain.
  void _computeSegments() {
    final line = widget.line;
    final spans = widget.spans;
    int cursor = 0;
    int wordIdx = 0;
    for (var i = 0; i + 2 < spans.length; i += 3) {
      final start = spans[i];
      final end = spans[i + 1];
      final startMs = spans[i + 2];
      if (start < cursor || end <= start || end > line.length) continue;

      final currentWordIdx = wordIdx;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _onWordTap(currentWordIdx, startMs);
      _segments.add(_WordSegment(
        line.substring(cursor, start),
        line.substring(start, end),
        currentWordIdx,
        recognizer,
      ));

      cursor = end;
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
