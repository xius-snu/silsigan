import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/tts_provider.dart';
import '../../utils/constants.dart';

/// Speaker icon that toggles TTS on tap. When the user taps to ENABLE TTS,
/// a small popup with a speed slider appears anchored below the icon.
/// Tap-away (anywhere outside the popup) dismisses it.
///
/// The slider drives the global [ttsRateProvider] (persisted), so all
/// TtsService instances pick up the same speed.
class TtsControlButton extends ConsumerStatefulWidget {
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final double iconSize;
  final Color? activeColor;
  final Color? inactiveColor;

  /// Optional async gate run when the user taps to ENABLE. If it resolves
  /// false, the toggle is cancelled (stays off, no speed popup). Used by
  /// Conversation mode to prompt for headphones before turning the speaker on.
  final Future<bool> Function()? confirmEnable;

  const TtsControlButton({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
    this.iconSize = 20,
    this.activeColor,
    this.inactiveColor,
    this.confirmEnable,
  });

  @override
  ConsumerState<TtsControlButton> createState() => _TtsControlButtonState();
}

class _TtsControlButtonState extends ConsumerState<TtsControlButton> {
  final GlobalKey _iconKey = GlobalKey();
  OverlayEntry? _overlay;

  @override
  void dispose() {
    _hidePopup();
    super.dispose();
  }

  void _showPopup() {
    if (_overlay != null) return;

    final renderBox = _iconKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final iconPos = renderBox.localToGlobal(Offset.zero);
    final iconSize = renderBox.size;
    final screenSize = MediaQuery.of(context).size;

    // Right-align the popup with the icon when there's room; otherwise
    // clamp to a small inset from the screen edges.
    const popupWidth = 240.0;
    final iconRight = iconPos.dx + iconSize.width;
    double leftPos = iconRight - popupWidth;
    if (leftPos < 8) leftPos = 8;
    if (leftPos + popupWidth > screenSize.width - 8) {
      leftPos = screenSize.width - popupWidth - 8;
    }
    final topPos = iconPos.dy + iconSize.height + 6;

    _overlay = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            // Tap-outside dismiss layer.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _hidePopup,
              ),
            ),
            Positioned(
              left: leftPos,
              top: topPos,
              width: popupWidth,
              child: Consumer(builder: (context, ref, _) {
                final rate = ref.watch(ttsRateProvider);
                return Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  color: AppConstants.panelColor,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.speed,
                              size: 14,
                              color: AppConstants.textSecondary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Speed',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppConstants.textSecondary,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${(rate * 100).round()}%',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppConstants.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                            ),
                          ),
                          child: Slider(
                            value: rate,
                            min: 0.5,
                            max: 1.5,
                            divisions: 20,
                            activeColor: AppConstants.textPrimary,
                            inactiveColor: AppConstants.dividerColor,
                            onChanged: (v) {
                              ref.read(ttsRateProvider.notifier).state = v;
                            },
                            onChangeEnd: (v) {
                              saveTtsRate(v);
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Slow',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppConstants.textSecondary,
                                ),
                              ),
                              Text(
                                'Fast',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppConstants.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_overlay!);
  }

  void _hidePopup() {
    _overlay?.remove();
    _overlay = null;
  }

  Future<void> _onTap() async {
    final wasEnabled = widget.enabled;
    if (!wasEnabled && widget.confirmEnable != null) {
      // Gate the enable (e.g. Conversation's headphone prompt). Bail on decline.
      final ok = await widget.confirmEnable!();
      if (!ok || !mounted) return;
    }
    widget.onEnabledChanged(!wasEnabled);
    if (!wasEnabled) {
      // Just turned on — show the speed popup.
      WidgetsBinding.instance.addPostFrameCallback((_) => _showPopup());
    } else {
      // Just turned off — hide popup if it was open.
      _hidePopup();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _iconKey,
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          widget.enabled ? Icons.volume_up : Icons.volume_off_outlined,
          size: widget.iconSize,
          color: widget.enabled
              ? (widget.activeColor ?? AppConstants.textPrimary)
              : (widget.inactiveColor ?? AppConstants.textSecondary),
        ),
      ),
    );
  }
}
