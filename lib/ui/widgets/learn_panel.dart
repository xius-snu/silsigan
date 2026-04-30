import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../providers/learn_provider.dart';
import '../../providers/native_language_provider.dart';
import '../../providers/target_language_provider.dart';
import '../../services/audio_service.dart';
import '../../services/claude_chat_service.dart';
import '../../services/soniox_realtime_service.dart';
import '../../services/tts_service.dart';
import '../../services/user_service.dart';
import '../../providers/tts_provider.dart';
import '../../utils/constants.dart';
import 'tts_control_button.dart';

/// Learn mode: 1:1 conversation with Claude in a target language for
/// speaking practice. User speaks → ASR → Claude → TTS reply.
class LearnPanel extends ConsumerStatefulWidget {
  const LearnPanel({super.key});

  @override
  ConsumerState<LearnPanel> createState() => _LearnPanelState();
}

class _LearnPanelState extends ConsumerState<LearnPanel> {
  final AudioService _audio = AudioService();
  final SonioxRealtimeService _soniox = SonioxRealtimeService();
  final TtsService _tts = TtsService();
  final ClaudeChatService _claude = ClaudeChatService();
  final ScrollController _scrollController = ScrollController();

  /// Accumulated finalized utterances for the in-progress message.
  /// Mutated only by the onTranscriptionCompleted callback.
  String _finalizedText = '';

  /// The current in-flight utterance from Soniox (provisional + pending).
  /// Mutated only by the onTranscriptionDraft callback. Replaces wholesale.
  String _liveDraft = '';

  bool _isRecording = false;
  bool _isStopping = false;

  /// Set true between a backspace/clear tap and the resulting Soniox
  /// completion event (triggered by finalize). While true, drafts and the
  /// next completion are ignored — they reflect the pre-deletion state.
  bool _pendingFinalize = false;

  /// Safety net for [_pendingFinalize]: if no completion event arrives within
  /// this window (Soniox sometimes doesn't fire one when there's nothing in
  /// flight), force-clear the flag so subsequent drafts aren't dropped forever.
  Timer? _pendingFinalizeTimer;

  String get _displayedTranscript =>
      ('$_finalizedText $_liveDraft').replaceAll(RegExp(r'\s+'), ' ').trim();

  @override
  void initState() {
    super.initState();
    _setupSoniox();
    _setupTts();
  }

  @override
  void dispose() {
    _pendingFinalizeTimer?.cancel();
    _audio.dispose();
    _soniox.disconnect();
    _tts.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setupSoniox() {
    _soniox.userId = UserService.instance.userId;
    _soniox.authToken = UserService.instance.authToken;

    _soniox.onTranscriptionDraft = (draft) {
      if (!mounted) return;
      // Ignore drafts produced from the pre-deletion utterance.
      if (_pendingFinalize) return;
      setState(() => _liveDraft = draft);
      _scrollToBottom(jump: true);
    };

    _soniox.onTranscriptionCompleted = (text) {
      if (!mounted) return;
      // While clear-and-stop is in flight, drop everything Soniox emits —
      // both drafts (above) and completions. The teardown caller manages the
      // flag's lifetime; we just gate.
      if (_pendingFinalize) return;
      // Move the finalized utterance into _finalizedText. The draft callback
      // will replace _liveDraft on the next utterance — don't touch it here.
      setState(() {
        _finalizedText =
            _finalizedText.isEmpty ? text : '$_finalizedText $text';
        _liveDraft = '';
      });
      _scrollToBottom(jump: true);
    };

    _soniox.onError = (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Speech error: $err')),
      );
    };
  }

  void _setupTts() {
    _tts.onError = (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err)),
      );
    };
  }

  Future<void> _startRecording() async {
    if (_isRecording || ref.read(learnLoadingProvider)) return;

    final micGranted = await Permission.microphone.request().isGranted;
    if (!micGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission required')),
      );
      return;
    }

    final speakingLang = ref.read(targetLanguageProvider).code;

    // Preserve any existing finalized text — re-pressing mic continues from
    // where the user left off. Only the clear button (or a successful submit)
    // wipes the transcript. _liveDraft is reset because Soniox starts a fresh
    // utterance on connect.
    setState(() {
      _isRecording = true;
      _liveDraft = '';
    });

    try {
      // Connect Soniox WITHOUT a translation target → ASR-only.
      await _soniox.connect(languageHint: speakingLang);

      _audio.onAudioChunk = (bytes) => _soniox.sendAudio(bytes);
      await _audio.start();
    } catch (e) {
      setState(() => _isRecording = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start: $e')),
      );
    }
  }

  /// Stop the audio + Soniox session, but KEEP the transcript on screen.
  /// The user can then submit, clear, or re-record.
  Future<void> _stopRecording() async {
    if (!_isRecording || _isStopping) return;
    _isStopping = true;

    setState(() => _isRecording = false);

    try {
      await _audio.stop();
      _soniox.finalize();
      // Give the final completion event time to land before disconnecting,
      // so _finalizedText is fully populated.
      await Future.delayed(const Duration(milliseconds: 800));
      await _soniox.disconnect();
    } catch (_) {}

    _isStopping = false;
  }

  /// Tear the recording session down without preserving anything Soniox is
  /// holding in flight. Used by clear-while-recording so the next session
  /// starts from a clean slate (no bleed from the previous audio).
  Future<void> _clearAndStopRecording() async {
    // Gate ALL callbacks for the whole teardown. The 2s safety timer is a
    // belt-and-suspenders fallback in case disconnect hangs — without it
    // the flag could stick true forever and silently swallow future drafts.
    _pendingFinalize = true;
    _pendingFinalizeTimer?.cancel();
    _pendingFinalizeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _pendingFinalize = false;
    });

    setState(() {
      _isRecording = false;
      _finalizedText = '';
      _liveDraft = '';
    });

    try {
      await _audio.stop();
      // Hard disconnect — no finalize. We don't want a flush event repainting
      // the cleared text. Any in-flight tokens get dropped at the WS layer.
      await _soniox.disconnect();
    } catch (_) {}

    _pendingFinalizeTimer?.cancel();
    if (mounted) _pendingFinalize = false;
  }

  /// Submit the current transcript to Claude. If still recording, stop first
  /// so the final tokens land before we read [_displayedTranscript].
  Future<void> _submitTranscript() async {
    if (ref.read(learnLoadingProvider)) return;

    // Show the spinner immediately so the user gets feedback while the
    // recording is being torn down.
    ref.read(learnLoadingProvider.notifier).state = true;

    if (_isRecording) {
      await _stopRecording();
    }
    if (!mounted) return;

    final transcript = _displayedTranscript;
    if (transcript.isEmpty) {
      ref.read(learnLoadingProvider.notifier).state = false;
      return;
    }

    setState(() {
      _finalizedText = '';
      _liveDraft = '';
    });

    await _sendToClaude(transcript);
  }

  Future<void> _sendToClaude(String userText) async {
    final messages = ref.read(learnMessagesProvider);
    final speakingLang = ref.read(targetLanguageProvider).code;
    final nativeLang = ref.read(nativeLanguageProvider).code;

    final userMsg = LearnMessage(role: 'user', text: userText);
    final updated = [...messages, userMsg];
    ref.read(learnMessagesProvider.notifier).state = updated;
    ref.read(learnLoadingProvider.notifier).state = true;
    _scrollToBottom();

    // Reply + grade run in parallel — separate Claude calls.
    final replyFuture = _claude.sendMessage(
      history: updated,
      speakingLang: speakingLang,
      nativeLang: nativeLang,
    );
    final gradeFuture = _claude.grade(
      history: updated,
      speakingLang: speakingLang,
      nativeLang: nativeLang,
    );

    String? reply;
    GradeResult? grade;
    Object? replyError;
    Object? gradeError;

    try {
      reply = await replyFuture;
    } catch (e) {
      replyError = e;
    }
    try {
      grade = await gradeFuture;
    } catch (e) {
      gradeError = e;
    }

    if (!mounted) return;

    // Apply grade to the user message we just appended.
    final current = ref.read(learnMessagesProvider);
    final newList = [...current];
    final userIdx = newList.lastIndexWhere((m) => identical(m, userMsg));
    if (userIdx >= 0 && grade != null) {
      newList[userIdx].gradeStatus = grade.status;
      newList[userIdx].gradeExplanation =
          grade.status == GradeStatus.incorrect ? grade.explanation : null;
    }
    if (reply != null) {
      newList.add(LearnMessage(role: 'assistant', text: reply));
    }
    ref.read(learnMessagesProvider.notifier).state = newList;
    ref.read(learnLoadingProvider.notifier).state = false;
    _scrollToBottom();

    if (reply != null && ref.read(learnAutoTtsProvider)) {
      _tts.setLanguageCode(speakingLang);
      _tts.setEnabled(true);
      _tts.speak(reply);
    }

    if (replyError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$replyError')),
      );
    } else if (gradeError != null) {
      debugPrint('Grade error: $gradeError');
    }

    // Auto-mic: re-arm the mic after the assistant has replied. Wait for TTS
    // playback to fully drain first so the spoken reply doesn't get captured
    // by the recorder. waitForDrain returns immediately if TTS isn't queued.
    if (reply != null && ref.read(learnAutoMicProvider)) {
      await _tts.waitForDrain();
      if (!mounted) return;
      if (ref.read(learnAutoMicProvider) && !_isRecording && !_isStopping) {
        await _startRecording();
      }
    }
  }

  /// Hint flow: ask Claude what the user could say, append it as a user
  /// message, then get the assistant's reply — handing the turn back. No
  /// grading (the user didn't actually produce the message).
  Future<void> _hint() async {
    if (_isRecording || ref.read(learnLoadingProvider)) return;

    final speakingLang = ref.read(targetLanguageProvider).code;
    final nativeLang = ref.read(nativeLanguageProvider).code;

    ref.read(learnLoadingProvider.notifier).state = true;
    _scrollToBottom();

    String suggestion;
    try {
      suggestion = await _claude.suggestUserReply(
        history: ref.read(learnMessagesProvider),
        speakingLang: speakingLang,
        nativeLang: nativeLang,
      );
    } catch (e) {
      if (!mounted) return;
      ref.read(learnLoadingProvider.notifier).state = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
      return;
    }

    if (!mounted) return;
    if (suggestion.isEmpty) {
      ref.read(learnLoadingProvider.notifier).state = false;
      return;
    }

    // gradeStatus = na hides the grade chip (we don't grade AI-written turns).
    final userMsg = LearnMessage(
      role: 'user',
      text: suggestion,
      gradeStatus: GradeStatus.na,
    );
    final updated = [...ref.read(learnMessagesProvider), userMsg];
    ref.read(learnMessagesProvider.notifier).state = updated;
    _scrollToBottom();

    String? reply;
    try {
      reply = await _claude.sendMessage(
        history: updated,
        speakingLang: speakingLang,
        nativeLang: nativeLang,
      );
    } catch (e) {
      if (!mounted) return;
      ref.read(learnLoadingProvider.notifier).state = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
      return;
    }

    if (!mounted) return;
    ref.read(learnMessagesProvider.notifier).state = [
      ...ref.read(learnMessagesProvider),
      LearnMessage(role: 'assistant', text: reply),
    ];
    ref.read(learnLoadingProvider.notifier).state = false;
    _scrollToBottom();

    if (ref.read(learnAutoTtsProvider)) {
      _tts.setLanguageCode(speakingLang);
      _tts.setEnabled(true);
      _tts.speak(reply);
    }
  }

  Future<void> _explain(int messageIndex) async {
    final messages = ref.read(learnMessagesProvider);
    if (messageIndex >= messages.length) return;
    final msg = messages[messageIndex];
    if (msg.explanation != null || msg.explainLoading) return;

    setState(() => msg.explainLoading = true);
    ref.read(learnMessagesProvider.notifier).state = [...messages];

    try {
      final speakingLang = ref.read(targetLanguageProvider).code;
      final nativeLang = ref.read(nativeLanguageProvider).code;
      final explanation = await _claude.explain(
        messageText: msg.text,
        speakingLang: speakingLang,
        nativeLang: nativeLang,
      );
      msg.explanation = explanation;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      msg.explainLoading = false;
      if (mounted) {
        ref.read(learnMessagesProvider.notifier).state =
            [...ref.read(learnMessagesProvider)];
      }
    }
  }

  void _clearTranscript() {
    if (_isRecording) {
      // Fire-and-forget: full teardown so old audio can't bleed into the
      // next session. Side buttons stay on clear+submit briefly while the
      // disconnect resolves; that's fine — submit is gated by hasText.
      _clearAndStopRecording();
      return;
    }
    if (_displayedTranscript.isEmpty) return;
    setState(() {
      _finalizedText = '';
      _liveDraft = '';
    });
  }

  void _replayTts(String text) {
    final speakingLang = ref.read(targetLanguageProvider).code;
    _tts.setLanguageCode(speakingLang);
    _tts.speakOnce(text);
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (jump) {
        _scrollController.jumpTo(max);
      } else {
        _scrollController.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toggleAutoTts() {
    final next = !ref.read(learnAutoTtsProvider);
    ref.read(learnAutoTtsProvider.notifier).state = next;
    saveLearnAutoTts(next);
    if (!next) _tts.stop();
  }

  void _clearChat() {
    ref.read(learnMessagesProvider.notifier).state = [];
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(learnMessagesProvider);
    final isLoading = ref.watch(learnLoadingProvider);
    final autoTts = ref.watch(learnAutoTtsProvider);
    final speakingLang = ref.watch(targetLanguageProvider);
    final nativeLang = ref.watch(nativeLanguageProvider);
    // Keep TTS service in sync with the global rate slider.
    _tts.setRate(ref.watch(ttsRateProvider));

    return Container(
      color: AppConstants.bgColor,
      child: Column(
        children: [
          _buildHeader(speakingLang, nativeLang, autoTts, messages.isNotEmpty),
          Expanded(
            child: Container(
              color: AppConstants.panelColor,
              child: messages.isEmpty &&
                      !_isRecording &&
                      _displayedTranscript.isEmpty
                  ? _buildEmptyState(speakingLang)
                  : _buildChatList(messages, isLoading),
            ),
          ),
          _buildBottomBar(isLoading),
        ],
      ),
    );
  }

  Widget _buildHeader(
    TargetLanguage speaking,
    TargetLanguage native,
    bool autoTts,
    bool hasMessages,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
      color: AppConstants.bgColor,
      child: Row(
        children: [
          Flexible(
            child: _buildLangPicker(
              label: 'Practicing',
              value: speaking,
              onChanged: (lang) {
                ref.read(targetLanguageProvider.notifier).state = lang;
                saveTargetLanguage(lang);
              },
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: _buildLangPicker(
              label: 'I speak',
              value: native,
              onChanged: (lang) {
                ref.read(nativeLanguageProvider.notifier).state = lang;
                saveNativeLanguage(lang);
              },
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Clear conversation',
            icon: Icon(
              Icons.refresh,
              size: 20,
              color: hasMessages
                  ? AppConstants.textSecondary
                  : AppConstants.textSecondary.withOpacity(0.35),
            ),
            onPressed: hasMessages ? _clearChat : null,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          TtsControlButton(
            enabled: autoTts,
            iconSize: 22,
            onEnabledChanged: (v) {
              if (v == autoTts) return;
              _toggleAutoTts();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLangPicker({
    required String label,
    required TargetLanguage value,
    required ValueChanged<TargetLanguage> onChanged,
  }) {
    return PopupMenuButton<TargetLanguage>(
      enabled: !_isRecording && !ref.read(learnLoadingProvider),
      onSelected: onChanged,
      itemBuilder: (_) => TargetLanguage.values
          .map(
            (lang) => PopupMenuItem<TargetLanguage>(
              value: lang,
              child: Row(
                children: [
                  Expanded(child: Text(lang.displayName)),
                  if (lang == value) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppConstants.panelColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$label: ',
              style: const TextStyle(
                fontSize: 12,
                color: AppConstants.textSecondary,
              ),
            ),
            Flexible(
              child: Text(
                value.displayName,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppConstants.textPrimary,
                ),
              ),
            ),
            const Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: AppConstants.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(TargetLanguage speaking) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.school_outlined,
              size: 56,
              color: AppConstants.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              'Practice ${speaking.displayName}',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppConstants.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap the mic and start a conversation. '
              'Tap Explain on any reply to see it in your language.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppConstants.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatList(List<LearnMessage> messages, bool isLoading) {
    final draft = _displayedTranscript;
    return SelectionArea(
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        itemCount: messages.length +
            (draft.isNotEmpty ? 1 : 0) +
            (isLoading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index < messages.length) {
            final m = messages[index];
            return _buildMessageBubble(m, index);
          }
          // Live recording draft (right-aligned, dimmed)
          if (draft.isNotEmpty && index == messages.length) {
            return _buildBubble(
              text: draft,
              isUser: true,
              isDraft: true,
            );
          }
          // Loading indicator (left-aligned)
          return _buildLoadingBubble();
        },
      ),
    );
  }

  Widget _buildMessageBubble(LearnMessage m, int index) {
    final isUser = m.role == 'user';
    return Column(
      crossAxisAlignment:
          isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _buildBubble(text: m.text, isUser: isUser),
        if (!isUser) _buildAssistantActions(m, index),
        if (isUser && m.gradeStatus != null && m.gradeStatus != GradeStatus.na)
          _buildGradeIndicator(m),
        if (isUser &&
            m.gradeStatus == GradeStatus.incorrect &&
            (m.gradeExplanation?.isNotEmpty ?? false))
          _buildGradeExplanation(m.gradeExplanation!),
        if (!isUser && m.explanation != null)
          Container(
            margin: const EdgeInsets.only(top: 4, right: 40, bottom: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF4D6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              m.explanation!,
              style: const TextStyle(
                fontSize: 13,
                color: AppConstants.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildGradeIndicator(LearnMessage m) {
    final isCorrect = m.gradeStatus == GradeStatus.correct;
    final color = isCorrect ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCorrect ? Icons.check_circle : Icons.cancel,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            isCorrect ? 'Correct' : 'Incorrect',
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGradeExplanation(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 4, left: 40),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFFFEBEE),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFFCDD2)),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            color: AppConstants.textPrimary,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildBubble({
    required String text,
    required bool isUser,
    bool isDraft = false,
  }) {
    final bubbleColor = isUser ? const Color(0xFF111111) : const Color(0xFFF0F0F0);
    final textColor = isUser ? Colors.white : AppConstants.textPrimary;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isDraft ? bubbleColor.withOpacity(0.6) : bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppConstants.contentFontSize,
            color: textColor,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantActions(LearnMessage m, int index) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => _replayTts(m.text),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                Icons.volume_up_outlined,
                size: 16,
                color: AppConstants.textSecondary,
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: m.text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                Icons.copy,
                size: 14,
                color: AppConstants.textSecondary,
              ),
            ),
          ),
          GestureDetector(
            onTap: m.explainLoading ? null : () => _explain(index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: m.explainLoading
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : Text(
                      m.explanation == null ? 'Explain' : 'Hide explain',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppConstants.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const _TypingDots(),
      ),
    );
  }

  Widget _buildBottomBar(bool isLoading) {
    final autoMic = ref.watch(learnAutoMicProvider);
    final hasText = _displayedTranscript.isNotEmpty;
    // Show the clear+submit pair while there's anything to act on — either
    // an active recording session OR text waiting to be sent. Otherwise fall
    // back to the idle pair (auto-mic toggle + hint).
    final showActionPair = _isRecording || hasText;
    return Container(
      color: AppConstants.bgColor,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 120),
            child: showActionPair
                ? _buildClearButton(key: const ValueKey('clear'))
                : _buildAutoMicToggle(autoMic, key: const ValueKey('auto-mic')),
          ),
          const SizedBox(width: 40),
          _buildMicButton(isLoading),
          const SizedBox(width: 40),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 120),
            child: showActionPair
                ? _buildSubmitButton(isLoading, hasText,
                    key: const ValueKey('submit'))
                : _buildHintButton(isLoading, key: const ValueKey('hint')),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton(bool isLoading, bool hasText, {Key? key}) {
    final enabled = hasText && !isLoading;
    return GestureDetector(
      key: key,
      onTap: enabled ? _submitTranscript : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: AppConstants.sideButtonSize,
        height: AppConstants.sideButtonSize,
        decoration: BoxDecoration(
          color: enabled
              ? AppConstants.historyButtonColor
              : AppConstants.saveButtonColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.10),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: const Icon(
          Icons.arrow_upward,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }

  Widget _buildHintButton(bool isLoading, {Key? key}) {
    final disabled = isLoading;
    return GestureDetector(
      key: key,
      onTap: disabled ? null : _hint,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: AppConstants.sideButtonSize,
        height: AppConstants.sideButtonSize,
        decoration: BoxDecoration(
          color: disabled
              ? AppConstants.saveButtonColor
              : AppConstants.historyButtonColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.10),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: const Icon(
          Icons.auto_awesome,
          color: Colors.white,
          size: 22,
        ),
      ),
    );
  }

  Widget _buildClearButton({Key? key}) {
    // Enabled whenever there's something to clear — text, an active recording
    // session, or both. While recording with no text, clear acts as "cancel
    // without sending" (it stops + tears down the Soniox session).
    final enabled = _isRecording || _displayedTranscript.isNotEmpty;
    return GestureDetector(
      key: key,
      onTap: enabled ? _clearTranscript : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: AppConstants.sideButtonSize,
        height: AppConstants.sideButtonSize,
        decoration: BoxDecoration(
          color: enabled
              ? AppConstants.historyButtonColor
              : AppConstants.saveButtonColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.10),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: const Icon(
          Icons.delete_outline,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }

  Widget _buildAutoMicToggle(bool enabled, {Key? key}) {
    return GestureDetector(
      key: key,
      onTap: () {
        final next = !ref.read(learnAutoMicProvider);
        ref.read(learnAutoMicProvider.notifier).state = next;
        saveLearnAutoMic(next);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: AppConstants.sideButtonSize,
        height: AppConstants.sideButtonSize,
        decoration: BoxDecoration(
          color: enabled
              ? AppConstants.historyButtonColor
              : AppConstants.panelColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled
                ? AppConstants.historyButtonColor
                : AppConstants.dividerColor,
            width: 1,
          ),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.10),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.autorenew,
              size: 18,
              color: enabled ? Colors.white : AppConstants.textSecondary,
            ),
            const SizedBox(height: 1),
            Text(
              'AUTO',
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: enabled ? Colors.white : AppConstants.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMicButton(bool isLoading) {
    final disabled = isLoading;
    final bg = AppConstants.micButtonColor;

    Widget icon;
    VoidCallback? onTap;

    if (isLoading) {
      icon = const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: Colors.white,
        ),
      );
      onTap = null;
    } else if (_isRecording) {
      icon = const Icon(Icons.stop, color: Colors.white, size: 32);
      onTap = _stopRecording;
    } else {
      icon = const Icon(Icons.mic, color: Colors.white, size: 36);
      onTap = _startRecording;
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: AppConstants.micButtonSize,
        height: AppConstants.micButtonSize,
        decoration: BoxDecoration(
          color: disabled ? bg.withOpacity(0.6) : bg,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(child: icon),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 14,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final phase = (_ctrl.value * 3 - i).clamp(0.0, 1.0);
              final opacity = 0.3 + (phase < 0.5 ? phase : 1 - phase) * 1.4;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Opacity(
                  opacity: opacity.clamp(0.3, 1.0),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppConstants.textSecondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
