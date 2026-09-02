import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/desktop_audio_source_provider.dart';
import '../../services/desktop_audio_devices.dart';
import '../../utils/constants.dart';
import '../../utils/desktop.dart';

/// Header control for mic / speaker / both, plus device pickers. Shown on
/// desktop, iPhone, iPad, and Android.
class DesktopAudioSourceButton extends ConsumerStatefulWidget {
  const DesktopAudioSourceButton({
    super.key,
    required this.enabled,
  });

  final bool enabled;

  @override
  ConsumerState<DesktopAudioSourceButton> createState() =>
      _DesktopAudioSourceButtonState();
}

enum _DeviceField { mic, speaker }

class _DesktopAudioSourceButtonState
    extends ConsumerState<DesktopAudioSourceButton> {
  final GlobalKey _iconKey = GlobalKey();
  final GlobalKey _panelKey = GlobalKey();
  OverlayEntry? _overlay;
  List<DesktopAudioDevice> _mics = const [];
  List<DesktopAudioDevice> _speakers = const [];
  bool _loading = false;
  _DeviceField? _expanded;

  @override
  void dispose() {
    _hidePopup();
    super.dispose();
  }

  String get _speakerHint {
    if (!isMobileSpeakerCapture) {
      return 'Speaker listens to what’s playing on that device. Use headphones if voice playback is on.';
    }
    if (isIOSPlatform) {
      return 'You’ll be asked to Start Broadcast (red status bar). Screen audio only — the picker mic is off so it isn’t captured twice.';
    }
    if (isAndroidPlatform) {
      return 'Android will ask to capture screen audio. DRM and call audio stay silent.';
    }
    return 'Speaker listens to what’s playing. Use headphones if voice playback is on.';
  }

  IconData _iconFor(DesktopAudioSource source) {
    switch (source) {
      case DesktopAudioSource.microphone:
        return Icons.mic_none_outlined;
      case DesktopAudioSource.speaker:
        return Icons.volume_up_outlined;
      case DesktopAudioSource.both:
        return Icons.spatial_audio_outlined;
    }
  }

  Future<void> _refreshDevices() async {
    setState(() => _loading = true);
    _overlay?.markNeedsBuild();
    try {
      final results = await Future.wait([
        DesktopAudioDevices.listInputs(),
        DesktopAudioDevices.listOutputs(),
      ]);
      if (!mounted) return;
      setState(() {
        _mics = results[0];
        _speakers = results[1];
        _loading = false;
      });
      _overlay?.markNeedsBuild();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _overlay?.markNeedsBuild();
    }
  }

  void _showPopup() {
    if (_overlay != null || !widget.enabled) return;
    _expanded = null;
    _refreshDevices();

    final renderBox = _iconKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final iconPos = renderBox.localToGlobal(Offset.zero);
    final iconSize = renderBox.size;
    final screenSize = MediaQuery.of(context).size;

    const popupWidth = 300.0;
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
            // Dismiss only on a press that starts outside the panel. A
            // competing GestureDetector+PopupMenu used to eat the device
            // tap, remove this overlay, and drop the selection.
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  final box = _panelKey.currentContext?.findRenderObject()
                      as RenderBox?;
                  if (box != null && box.hasSize && box.attached) {
                    final local = box.globalToLocal(event.position);
                    if (box.size.contains(local)) return;
                  }
                  _hidePopup();
                },
              ),
            ),
            Positioned(
              left: leftPos,
              top: topPos,
              width: popupWidth,
              child: Consumer(builder: (context, ref, _) {
                final settings = ref.watch(desktopAudioSettingsProvider);
                return Material(
                  key: _panelKey,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  color: AppConstants.panelColor,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Audio source',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppConstants.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            _ModeChip(
                              label: 'Mic',
                              selected: settings.source ==
                                  DesktopAudioSource.microphone,
                              onTap: () =>
                                  _setSource(DesktopAudioSource.microphone),
                            ),
                            const SizedBox(width: 6),
                            _ModeChip(
                              label: 'Speaker',
                              selected:
                                  settings.source == DesktopAudioSource.speaker,
                              enabled: desktopSpeakerCaptureSupported,
                              onTap: () =>
                                  _setSource(DesktopAudioSource.speaker),
                            ),
                            const SizedBox(width: 6),
                            _ModeChip(
                              label: 'Both',
                              selected:
                                  settings.source == DesktopAudioSource.both,
                              enabled: desktopSpeakerCaptureSupported,
                              onTap: () => _setSource(DesktopAudioSource.both),
                            ),
                          ],
                        ),
                        if (!desktopSpeakerCaptureSupported) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Speaker capture isn’t available on this device.',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppConstants.textMuted,
                            ),
                          ),
                        ] else if (settings.captureSpeaker) ...[
                          const SizedBox(height: 8),
                          Text(
                            _speakerHint,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppConstants.textMuted,
                            ),
                          ),
                        ],
                        if (settings.captureMic) ...[
                          const SizedBox(height: 12),
                          _DeviceRow(
                            label: 'Microphone',
                            selectedId: settings.micDeviceId,
                            devices: _mics,
                            loading: _loading,
                            expanded: _expanded == _DeviceField.mic,
                            onToggle: () => _toggleExpanded(_DeviceField.mic),
                            onSelected: (id) => _setDevices(micId: id),
                          ),
                        ],
                        if (settings.captureSpeaker &&
                            desktopSpeakerCaptureSupported) ...[
                          const SizedBox(height: 10),
                          _DeviceRow(
                            label: 'Speaker',
                            selectedId: settings.speakerDeviceId,
                            devices: _speakers,
                            loading: _loading,
                            emptyHint: 'No speaker devices found',
                            expanded: _expanded == _DeviceField.speaker,
                            onToggle: () =>
                                _toggleExpanded(_DeviceField.speaker),
                            onSelected: (id) => _setDevices(speakerId: id),
                          ),
                        ],
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
    _expanded = null;
    _overlay?.remove();
    _overlay = null;
  }

  void _toggleExpanded(_DeviceField field) {
    setState(() {
      _expanded = _expanded == field ? null : field;
    });
    _overlay?.markNeedsBuild();
  }

  void _setSource(DesktopAudioSource source) {
    if (!desktopSpeakerCaptureSupported &&
        source != DesktopAudioSource.microphone) {
      return;
    }
    final next =
        ref.read(desktopAudioSettingsProvider).copyWith(source: source);
    ref.read(desktopAudioSettingsProvider.notifier).state = next;
    saveDesktopAudioSettings(next);
    setState(() => _expanded = null);
    _overlay?.markNeedsBuild();
  }

  void _setDevices({String? micId, String? speakerId}) {
    final current = ref.read(desktopAudioSettingsProvider);
    final next = current.copyWith(
      micDeviceId: micId,
      speakerDeviceId: speakerId,
      clearMicDevice: micId != null && micId.isEmpty,
      clearSpeakerDevice: speakerId != null && speakerId.isEmpty,
    );
    ref.read(desktopAudioSettingsProvider.notifier).state = next;
    saveDesktopAudioSettings(next);
    setState(() => _expanded = null);
    _overlay?.markNeedsBuild();
  }

  void _onTap() {
    if (!widget.enabled) return;
    HapticFeedback.selectionClick();
    if (_overlay != null) {
      _hidePopup();
    } else {
      _showPopup();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(desktopAudioSettingsProvider);
    final active = settings.source != DesktopAudioSource.microphone;
    return GestureDetector(
      key: _iconKey,
      onTap: _onTap,
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: widget.enabled
            ? 'Audio source'
            : 'Stop recording to change the audio source',
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            _iconFor(settings.source),
            size: 24,
            color: !widget.enabled
                ? AppConstants.textFaint
                : active
                    ? AppConstants.textPrimary
                    : AppConstants.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (!enabled) {
      bg = AppConstants.bgColor;
      fg = AppConstants.textFaint;
    } else if (selected) {
      bg = AppConstants.micButtonColor;
      fg = AppConstants.micIconColor;
    } else {
      bg = AppConstants.bgColor;
      fg = AppConstants.textSecondary;
    }
    return Expanded(
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.label,
    required this.selectedId,
    required this.devices,
    required this.loading,
    required this.expanded,
    required this.onToggle,
    required this.onSelected,
    this.emptyHint,
  });

  final String label;
  final String? selectedId;
  final List<DesktopAudioDevice> devices;
  final bool loading;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelected;
  final String? emptyHint;

  @override
  Widget build(BuildContext context) {
    DesktopAudioDevice? selected;
    for (final d in devices) {
      if (d.id == selectedId) {
        selected = d;
        break;
      }
    }
    final display = selectedId == null || selectedId!.isEmpty
        ? 'Default'
        : (selected?.label ?? selectedId!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: AppConstants.textMuted,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: onToggle,
          child: Container(
            width: double.infinity,
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: AppConstants.bgColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    loading && devices.isEmpty ? 'Loading…' : display,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                ),
                if (loading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppConstants.textMuted,
                    ),
                  )
                else
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppConstants.textSecondary,
                  ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppConstants.bgColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                _DeviceOption(
                  label: 'Default',
                  selected: selectedId == null || selectedId!.isEmpty,
                  onTap: () => onSelected(''),
                ),
                ...devices.map(
                  (d) => _DeviceOption(
                    label: d.isDefault ? '${d.label} (default)' : d.label,
                    selected: d.id == selectedId,
                    onTap: () => onSelected(d.id),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (!loading && devices.isEmpty && emptyHint != null) ...[
          const SizedBox(height: 4),
          Text(
            emptyHint!,
            style: TextStyle(fontSize: 11, color: AppConstants.textMuted),
          ),
        ],
      ],
    );
  }
}

class _DeviceOption extends StatelessWidget {
  const _DeviceOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: AppConstants.textPrimary,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check, size: 18, color: AppConstants.textPrimary),
          ],
        ),
      ),
    );
  }
}
