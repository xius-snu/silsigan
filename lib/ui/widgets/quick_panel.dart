import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectionStatus;
import 'package:flutter/services.dart';
import '../../providers/recording_provider.dart';
import '../../providers/target_language_provider.dart';
import '../../utils/constants.dart';
import '../../utils/text_direction_utils.dart';
import 'tts_control_button.dart';
import 'source_language_selector.dart';

/// Quick Mode: a press-and-hold "walkie-talkie" translator.
///
/// Transcription fills the top half, translation the bottom half (both in
/// large text). Hold the mic to speak; release to stop input and hear the
/// translation spoken aloud. Self-contained like [ConversationPanel] — there
/// is no save/discard/history flow.
class QuickPanel extends StatefulWidget {
  final String transcript;
  final String translation;
  final RecordingState recordingState;
  final TargetLanguage targetLanguage;
  final TargetLanguage? sourceLanguage;
  final String? detectedLanguage;
  final bool speakerEnabled;
  final ValueChanged<bool> onSpeakerChanged;
  final VoidCallback onMicPressStart;
  final VoidCallback onMicPressEnd;
  final VoidCallback onClear;
  final VoidCallback onReplay;
  final ValueChanged<TargetLanguage?> onSourceChanged;
  final ValueChanged<TargetLanguage> onTargetLanguageChanged;

  /// Whether the languages are currently in the swapped ("reply") state. Drives
  /// the highlight on the language-row arrow so the user can tell a swap is active.
  final bool swapActive;

  /// Toggle the target language to the other side of the conversation (and back
  /// again on a second press). Fired by tapping the language-row arrow;
  /// implemented by the swap handler in MainScreen.
  final VoidCallback onSwap;

  const QuickPanel({
    super.key,
    required this.transcript,
    required this.translation,
    required this.recordingState,
    required this.targetLanguage,
    required this.sourceLanguage,
    required this.detectedLanguage,
    required this.speakerEnabled,
    required this.onSpeakerChanged,
    required this.onMicPressStart,
    required this.onMicPressEnd,
    required this.onClear,
    required this.onReplay,
    required this.onSourceChanged,
    required this.onTargetLanguageChanged,
    required this.swapActive,
    required this.onSwap,
  });

  @override
  State<QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends State<QuickPanel>
    with SingleTickerProviderStateMixin {
  final ScrollController _transcriptScroll = ScrollController();
  final ScrollController _translationScroll = ScrollController();
  // Selection state per half, read on demand (geometry-based ground truth)
  // rather than latched from SelectionArea.onSelectionChanged, which only
  // fires for gestures and would stay stale when the selected text is
  // replaced programmatically (next utterance / clear).
  final SelectionListenerNotifier _transcriptSelectionNotifier =
      SelectionListenerNotifier();
  final SelectionListenerNotifier _translationSelectionNotifier =
      SelectionListenerNotifier();

  // While a text selection is active in a half, that half's auto-scroll must
  // stay off: a jump mid-drag extends the selection over everything that
  // scrolls past, highlighting all the text.
  bool _hasActiveSelection(SelectionListenerNotifier notifier) =>
      notifier.registered &&
      notifier.selection.status == SelectionStatus.uncollapsed;
  late final AnimationController _scaleController;
  late final Animation<double> _scaleAnimation;
  int? _activePointer;
  Timer? _ellipsisTimer;
  int _ellipsisCount = 3;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeOut),
    );
    _syncEllipsisTimer();
  }

  // The animated dots only render in two narrow windows (recording with an
  // empty transcript / processing with an empty translation). Running the
  // timer unconditionally would setState the whole panel at 2.5Hz even while
  // the app sits fully idle in Quick mode.
  bool get _needsEllipsis =>
      (_isRecording && widget.transcript.isEmpty) ||
      (_isProcessing && widget.translation.isEmpty);

  void _syncEllipsisTimer() {
    if (_needsEllipsis && _ellipsisTimer == null) {
      _ellipsisTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (mounted) setState(() => _ellipsisCount = (_ellipsisCount % 3) + 1);
      });
    } else if (!_needsEllipsis && _ellipsisTimer != null) {
      _ellipsisTimer?.cancel();
      _ellipsisTimer = null;
    }
  }

  @override
  void didUpdateWidget(QuickPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncEllipsisTimer();
    if (widget.transcript != oldWidget.transcript &&
        !_hasActiveSelection(_transcriptSelectionNotifier)) {
      _scrollToBottom(_transcriptScroll);
    }
    if (widget.translation != oldWidget.translation &&
        !_hasActiveSelection(_translationSelectionNotifier)) {
      _scrollToBottom(_translationScroll);
    }
  }

  void _scrollToBottom(ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _ellipsisTimer?.cancel();
    _scaleController.dispose();
    _transcriptScroll.dispose();
    _translationScroll.dispose();
    _transcriptSelectionNotifier.dispose();
    _translationSelectionNotifier.dispose();
    super.dispose();
  }

  bool get _isRecording => widget.recordingState == RecordingState.recording;
  bool get _isProcessing => widget.recordingState == RecordingState.processing;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Transcription (top half)
        Expanded(
          child: _buildHalf(
            label: 'Transcription',
            text: widget.transcript,
            controller: _transcriptScroll,
            roundedTop: true,
            // Warm-up window: mic is live but the first tokens haven't arrived
            // yet — show a pulse so the panel isn't mistaken for a freeze.
            placeholder: _isRecording && widget.transcript.isEmpty
                ? '.' * _ellipsisCount
                : null,
          ),
        ),
        Container(height: 5, color: AppConstants.dividerColor),
        // Translation (bottom half)
        Expanded(
          child: _buildHalf(
            label: 'Translation',
            text: widget.translation,
            controller: _translationScroll,
            showSpeaker: true,
            // While translating after release, show a placeholder if nothing
            // has come back yet so the panel isn't blank.
            placeholder: _isProcessing && widget.translation.isEmpty
                ? '.' * _ellipsisCount
                : null,
          ),
        ),

        // Controls
        Container(
          color: AppConstants.bgColor,
          padding: const EdgeInsets.only(top: 16, bottom: 24),
          child: Column(
            children: [
              _buildLanguageRow(),
              const SizedBox(height: 18),
              _buildControlsRow(),
              const SizedBox(height: 10),
              _buildHint(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHalf({
    required String label,
    required String text,
    required ScrollController controller,
    bool roundedTop = false,
    bool showSpeaker = false,
    String? placeholder,
  }) {
    final display = text.isNotEmpty ? text : (placeholder ?? '');
    final isRtl = isRtlText(display);
    final showReplay = showSpeaker &&
        !_isRecording &&
        !_isProcessing &&
        text.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppConstants.panelColor,
        borderRadius: roundedTop
            ? const BorderRadius.only(
                topLeft: Radius.circular(AppConstants.panelBorderRadius),
                topRight: Radius.circular(AppConstants.panelBorderRadius),
              )
            : null,
      ),
      // Label + body sit in the normal layout flow and are IDENTICAL for both
      // halves, so the body text starts at the same vertical offset in each.
      // The speaker/replay controls are floated in a Stack overlay so they
      // don't grow the header and push the translation text down — it stays
      // aligned with the transcription text above.
      child: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  left: AppConstants.panelPaddingH,
                  top: 20,
                  bottom: 4,
                  right: 8,
                ),
                child: Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: AppConstants.labelFontSize,
                    fontWeight: FontWeight.w400,
                    color: AppConstants.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Expanded(
                child: SelectionArea(
                  child: SelectionListener(
                    selectionNotifier: controller == _transcriptScroll
                        ? _transcriptSelectionNotifier
                        : _translationSelectionNotifier,
                    child: SingleChildScrollView(
                      controller: controller,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppConstants.panelPaddingH,
                        vertical: 8,
                      ),
                      child: Align(
                        alignment:
                            isRtl ? Alignment.topRight : Alignment.topLeft,
                        child: Text(
                          display,
                          textDirection:
                              isRtl ? TextDirection.rtl : TextDirection.ltr,
                          style: const TextStyle(
                            fontSize: AppConstants.quickFontSize,
                            color: AppConstants.textPrimary,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (showSpeaker)
            Positioned(
              top: 14,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Replay: re-speak the current translation on demand (works
                  // even when the speaker toggle is muted). Only shown when
                  // there's a settled translation to replay.
                  if (showReplay)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        widget.onReplay();
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.replay,
                          size: 20,
                          color: AppConstants.textPrimary,
                        ),
                      ),
                    ),
                  TtsControlButton(
                    enabled: widget.speakerEnabled,
                    onEnabledChanged: widget.onSpeakerChanged,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLanguageRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SourceLanguageSelector(
          source: widget.sourceLanguage,
          detectedLanguage: widget.detectedLanguage,
          isRecording: _isRecording || _isProcessing,
          enabled: !_isRecording && !_isProcessing,
          onChanged: widget.onSourceChanged,
        ),
        // Tappable swap arrow: flips source ↔ target (or, with an "Any" source
        // mid-session, points the target at the last-detected language so the
        // listener can reply). A second press reverts. Disabled while recording.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: (_isRecording || _isProcessing)
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  widget.onSwap();
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.swapActive
                    ? AppConstants.micButtonColor
                    : Colors.transparent,
              ),
              child: Icon(
                widget.swapActive ? Icons.swap_horiz : Icons.arrow_forward,
                size: 27,
                color:
                    widget.swapActive ? Colors.white : AppConstants.textPrimary,
              ),
            ),
          ),
        ),
        PopupMenuButton<TargetLanguage>(
          enabled: !_isRecording && !_isProcessing,
          onSelected: widget.onTargetLanguageChanged,
          offset: const Offset(0, -160),
          itemBuilder: (context) => TargetLanguage.values
              .map(
                (lang) => PopupMenuItem<TargetLanguage>(
                  value: lang,
                  child: Row(
                    children: [
                      Expanded(child: Text(lang.displayName)),
                      if (lang == widget.targetLanguage)
                        const Icon(Icons.check, size: 18),
                    ],
                  ),
                ),
              )
              .toList(),
          child: Container(
            width: AppConstants.langBoxWidth,
            height: AppConstants.langBoxHeight,
            decoration: BoxDecoration(
              color: AppConstants.panelColor,
              borderRadius: BorderRadius.circular(AppConstants.langBoxRadius),
            ),
            alignment: Alignment.center,
            child: Text(
              widget.targetLanguage.displayName,
              style: const TextStyle(
                fontSize: AppConstants.langFontSize,
                color: AppConstants.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControlsRow() {
    final hasText = widget.transcript.trim().isNotEmpty ||
        widget.translation.trim().isNotEmpty;
    // The clear button only appears when there's something to clear and we're
    // not mid-recording. Swapping now lives on the language-row arrow, so the
    // right slot is just an empty placeholder matching the clear button's slot
    // to keep the mic centered.
    final showClear = !_isRecording && !_isProcessing && hasText;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildClearButton(showClear),
        const SizedBox(width: 40),
        _buildMicButton(),
        const SizedBox(width: 40),
        const SizedBox(
          width: AppConstants.sideButtonSize,
          height: AppConstants.sideButtonSize,
        ),
      ],
    );
  }

  Widget _buildClearButton(bool show) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      child: show
          ? GestureDetector(
              key: const ValueKey('quick-clear'),
              onTap: () {
                HapticFeedback.mediumImpact();
                widget.onClear();
              },
              child: Container(
                width: AppConstants.sideButtonSize,
                height: AppConstants.sideButtonSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.red,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.delete_outline,
                  color: Colors.white,
                  size: AppConstants.sideIconSize,
                ),
              ),
            )
          : const SizedBox(
              key: ValueKey('quick-clear-empty'),
              width: AppConstants.sideButtonSize,
              height: AppConstants.sideButtonSize,
            ),
    );
  }

  Widget _buildMicButton() {
    const size = AppConstants.micButtonSize;

    if (_isProcessing) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.red.withOpacity(0.8),
          boxShadow: [
            BoxShadow(
              color: Colors.red.withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          ),
        ),
      );
    }

    return Listener(
      onPointerDown: (event) {
        if (_activePointer != null) return;
        _activePointer = event.pointer;
        HapticFeedback.mediumImpact();
        _scaleController.forward();
        widget.onMicPressStart();
      },
      onPointerUp: (event) {
        if (event.pointer != _activePointer) return;
        _activePointer = null;
        _scaleController.reverse();
        widget.onMicPressEnd();
      },
      onPointerCancel: (event) {
        if (event.pointer != _activePointer) return;
        _activePointer = null;
        _scaleController.reverse();
        widget.onMicPressEnd();
      },
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) =>
            Transform.scale(scale: _scaleAnimation.value, child: child),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeInOut,
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isRecording ? Colors.red : AppConstants.micButtonColor,
            boxShadow: [
              BoxShadow(
                color: _isRecording
                    ? Colors.red.withOpacity(0.35)
                    : Colors.black.withOpacity(0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(
            Icons.mic,
            size: AppConstants.micIconSize,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildHint() {
    final String hint;
    if (_isProcessing) {
      hint = 'Translating…';
    } else if (_isRecording) {
      hint = 'Listening…';
    } else {
      hint = 'Hold to talk';
    }
    return Text(
      hint,
      style: TextStyle(
        fontSize: 13,
        color: Colors.grey[500],
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
