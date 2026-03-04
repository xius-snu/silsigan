import 'package:flutter/material.dart';
import '../../utils/constants.dart';

class BottomSideButton extends StatelessWidget {
  final IconData icon;
  final Color backgroundColor;
  final VoidCallback? onTap;

  const BottomSideButton({
    super.key,
    required this.icon,
    required this.backgroundColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: AppConstants.sideButtonSize,
        height: AppConstants.sideButtonSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: backgroundColor,
        ),
        child: Icon(
          icon,
          size: AppConstants.sideIconSize,
          color: Colors.white,
        ),
      ),
    );
  }
}
