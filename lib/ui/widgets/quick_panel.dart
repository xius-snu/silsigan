import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../providers/recording_provider.dart';
import '../../providers/target_language_provider.dart';
import '../../providers/detected_language_provider.dart';
import '../../utils/constants.dart';
import 'tts_control_button.dart';

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
  final String? detectedLanguage;
  final bool speakerEnabled;
  final ValueChanged<bool> onSpeakerChanged;
  final VoidCallback onMicPressStart;
  final VoidCallback onMicPressEnd;
  final VoidCallback onClear;
  final ValueChanged<TargetLanguage> onTargetLanguageChanged;

  const QuickPanel({
    super.key,
    required this.transcript,
    required this.translation,
    required this.recordingState,
    required this.targetLanguage,
    required this.detectedLanguage,
    required this.speakerEnabled,
    required this.onSpeakerChanged,
    required this.onMicPressStart,
    required this.onMicPressEnd,
    required this.onClear,
    required this.onTargetLanguageChanged,
  });

  @override
  State<QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends State<QuickPanel>
    with SingleTickerProviderStateMixin {
  final ScrollController _transcriptScroll = ScrollController();
  final ScrollController _translationScroll = ScrollController();
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
    _ellipsisTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) setState(() => _ellipsisCount = (_ellipsisCount % 3) + 1);
    });
  }

  @override
  void didUpdateWidget(QuickPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transcript != oldWidget.transcript) {
      _scrollToBottom(_transcriptScroll);
    }
    if (widget.translation != oldWidget.translation) {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppConstants.panelPaddingH,
              top: 14,
              bottom: 4,
              right: 8,
            ),
            child: Row(
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: AppConstants.labelFontSize,
                    fontWeight: FontWeight.w400,
                    color: AppConstants.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                if (showSpeaker)
                  TtsControlButton(
                    enabled: widget.speakerEnabled,
                    onEnabledChanged: widget.onSpeakerChanged,
                  ),
              ],
            ),
          ),
          Expanded(
            child: SelectionArea(
              child: SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppConstants.panelPaddingH,
                  vertical: 8,
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    display,
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
        ],
      ),
    );
  }

  Widget _buildLanguageRow() {
    final detected = widget.detectedLanguage;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: AppConstants.langBoxWidth,
          height: AppConstants.langBoxHeight,
          decoration: BoxDecoration(
            color: AppConstants.panelColor,
            borderRadius: BorderRadius.circular(AppConstants.langBoxRadius),
          ),
          alignment: Alignment.center,
          child: Text(
            detected != null ? languageDisplayName(detected) : 'Any',
            style: const TextStyle(
              fontSize: AppConstants.langFontSize,
              color: AppConstants.textPrimary,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Icon(
            Icons.arrow_forward,
            size: 27,
            color: AppConstants.textPrimary,
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
    // not mid-recording. A matching spacer on the right keeps the mic centered.
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
