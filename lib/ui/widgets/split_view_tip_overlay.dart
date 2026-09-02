import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../utils/constants.dart';

/// Coach-mark overlay that dims the screen, punches a hole over [targetRect]
/// (the settings gear), and shows a short tooltip with a caret pointing at it.
///
/// Taps on the dimmed area or the tooltip call [onDismiss]. Taps inside the
/// hole fall through to the gear underneath so the display-mode menu still
/// opens — opening the menu is the point of the tip.
class SplitViewTipOverlay extends StatelessWidget {
  const SplitViewTipOverlay({
    super.key,
    required this.targetRect,
    required this.onDismiss,
  });

  /// Gear bounds in global (overlay) coordinates.
  final Rect targetRect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    const tooltipWidth = 260.0;
    const caretSize = Size(16, 8);
    const gap = 10.0;

    final hole = targetRect.inflate(6);
    // Right-align the card under the gear, caret aimed at the hole center.
    double left = hole.center.dx - tooltipWidth + 28;
    left = left.clamp(
      12.0,
      (size.width - tooltipWidth - 12).clamp(12.0, size.width),
    );
    final top = hole.bottom + gap;
    final caretLeft = (hole.center.dx - left - caretSize.width / 2)
        .clamp(12.0, tooltipWidth - caretSize.width - 12);

    final dim =
        AppConstants.isDark ? const Color(0x8C000000) : const Color(0x59000000);

    return Stack(
      children: [
        Positioned.fill(
          child: _HolePassThrough(
            hole: hole,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: CustomPaint(
                painter: _DimWithHolePainter(hole: hole, color: dim),
              ),
            ),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: tooltipWidth,
          child: GestureDetector(
            onTap: onDismiss,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(left: caretLeft),
                  child: CustomPaint(
                    size: caretSize,
                    painter: _UpCaretPainter(AppConstants.panelColor),
                  ),
                ),
                Material(
                  color: AppConstants.panelColor,
                  elevation: 8,
                  shadowColor: Colors.black.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Switch to Split View for longer sessions',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tap the gear, then Split View.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: AppConstants.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Skips hit-testing inside [hole] so pointer events reach the gear below
/// this overlay entry.
class _HolePassThrough extends SingleChildRenderObjectWidget {
  const _HolePassThrough({required this.hole, required super.child});

  final Rect hole;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _HolePassThroughRender(hole: hole);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _HolePassThroughRender renderObject,
  ) {
    renderObject.hole = hole;
  }
}

class _HolePassThroughRender extends RenderProxyBox {
  _HolePassThroughRender({required Rect hole}) : _hole = hole;

  Rect _hole;
  set hole(Rect value) {
    if (_hole == value) return;
    _hole = value;
    markNeedsPaint();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_hole.contains(position)) return false;
    return super.hitTest(result, position: position);
  }
}

class _DimWithHolePainter extends CustomPainter {
  _DimWithHolePainter({required this.hole, required this.color});

  final Rect hole;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Path()..addRect(Offset.zero & size);
    final cut = Path()
      ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(10)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, overlay, cut),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _DimWithHolePainter old) =>
      old.hole != hole || old.color != color;
}

class _UpCaretPainter extends CustomPainter {
  _UpCaretPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _UpCaretPainter old) => old.color != color;
}
