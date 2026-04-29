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

  /// Set true between a backspace tap and the resulting Soniox completion
  /// event (triggered by finalize). While true, drafts and the next
  /// completion are ignored — they reflect the pre-deletion state.
  bool _pendingFinalize = false;

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
    };

    _soniox.onTranscriptionCompleted = (text) {
      if (!mounted) return;
      // Swallow the post-finalize completion that flushes the deleted text.
      if (_pendingFinalize) {
        _pendingFinalize = false;
        return;
      }
      // Move the finalized utterance into _finalizedText. The draft callback
      // will replace _liveDraft on the next utterance — don't touch it here.
      setState(() {
        _finalizedText =
            _finalizedText.isEmpty ? text : '$_finalizedText $text';
        _liveDraft = '';
      });
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

    setState(() {
      _isRecording = true;
      _finalizedText = '';
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

  Future<void> _stopRecording() async {
    if (!_isRecording || _isStopping) return;
    _isStopping = true;

    // Flip to spinner immediately — don't wait for audio teardown.
    setState(() => _isRecording = false);
    ref.read(learnLoadingProvider.notifier).state = true;

    try {
      await _audio.stop();
      _soniox.finalize();
      // Wait for final tokens to settle before disconnecting.
      await Future.delayed(const Duration(milliseconds: 800));
      // disconnect() flushes any remaining pending utterance via
      // onTranscriptionCompleted, which lands in _finalizedText.
      await _soniox.disconnect();
    } catch (_) {}

    final transcript = _displayedTranscript;
    setState(() {
      _finalizedText = '';
      _liveDraft = '';
    });
    _isStopping = false;

    if (transcript.isEmpty) {
      ref.read(learnLoadingProvider.notifier).state = false;
      return;
    }

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

  /// Remove the last word from [text]. Whitespace is the word boundary.
  /// Trailing punctuation is stripped before AND after the cut so a single
  /// tap removes "world." entirely, not just ".".
  static String _deleteLastWord(String text) {
    final endStrip = RegExp(
      r'''[\s.,;:!?。、，；：！？・…\-—–"'\)\]\}»」』]+$''',
      unicode: true,
    );
    var t = text.replaceAll(endStrip, '');
    if (t.isEmpty) return '';
    final lastSpace = t.lastIndexOf(RegExp(r'\s'));
    // No whitespace boundary in the remaining text → the entire chunk is a
    // single "word" (e.g. CJK text without spaces). Wipe it.
    if (lastSpace < 0) return '';
    t = t.substring(0, lastSpace);
    return t.replaceAll(endStrip, '');
  }

  void _backspace() {
    final current = _displayedTranscript;
    if (current.isEmpty) return;
    final next = _deleteLastWord(current);
    setState(() {
      _finalizedText = next;
      _liveDraft = '';
    });
    // While recording, force Soniox to flush its mid-utterance state so the
    // deleted suffix doesn't keep coming back via subsequent draft events.
    if (_isRecording && !_pendingFinalize) {
      _pendingFinalize = true;
      _soniox.finalize();
    }
  }

  void _replayTts(String text) {
    final speakingLang = ref.read(targetLanguageProvider).code;
    _tts.setLanguageCode(speakingLang);
    _tts.speakOnce(text);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
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
          _buildLangPicker(
            label: 'Practicing',
            value: speaking,
            onChanged: (lang) {
              ref.read(targetLanguageProvider.notifier).state = lang;
              saveTargetLanguage(lang);
            },
          ),
          const SizedBox(width: 8),
          _buildLangPicker(
            label: 'I speak',
            value: native,
            onChanged: (lang) {
              ref.read(nativeLanguageProvider.notifier).state = lang;
              saveNativeLanguage(lang);
            },
          ),
          const Spacer(),
          if (hasMessages)
            IconButton(
              tooltip: 'Clear conversation',
              icon: const Icon(
                Icons.refresh,
                size: 20,
                color: AppConstants.textSecondary,
              ),
              onPressed: _clearChat,
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
            Text(
              value.displayName,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppConstants.textPrimary,
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
    return Container(
      color: AppConstants.bgColor,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Left placeholder for symmetry with the right-side backspace.
          const SizedBox(
              width: AppConstants.sideButtonSize, height: AppConstants.sideButtonSize),
          const SizedBox(width: 40),
          _buildMicButton(isLoading),
          const SizedBox(width: 40),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 120),
            child: _isRecording
                ? _buildBackspaceButton(key: const ValueKey('backspace'))
                : const SizedBox(
                    key: ValueKey('backspace-hidden'),
                    width: AppConstants.sideButtonSize,
                    height: AppConstants.sideButtonSize,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackspaceButton({Key? key}) {
    final hasText = _displayedTranscript.isNotEmpty;
    return GestureDetector(
      key: key,
      onTap: hasText ? _backspace : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: AppConstants.sideButtonSize,
        height: AppConstants.sideButtonSize,
        decoration: BoxDecoration(
          color: hasText
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
          Icons.backspace_outlined,
          color: Colors.white,
          size: 22,
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
