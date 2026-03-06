import 'package:flutter/material.dart';
import '../../utils/constants.dart';

class IncomingInviteBanner extends StatelessWidget {
  final String friendCode;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const IncomingInviteBanner({
    super.key,
    required this.friendCode,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        border: Border(bottom: BorderSide(color: Colors.blue.shade100)),
      ),
      child: Row(
        children: [
          Icon(Icons.call_received, size: 18, color: Colors.blue.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$friendCode wants to start a session',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Colors.blue.shade900,
              ),
            ),
          ),
          GestureDetector(
            onTap: onAccept,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.shade600,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'Accept',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onReject,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Reject',
                style: TextStyle(
                    color: Colors.red.shade700,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OutgoingInviteBanner extends StatelessWidget {
  final String friendCode;
  final VoidCallback onCancel;

  const OutgoingInviteBanner({
    super.key,
    required this.friendCode,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        border: Border(bottom: BorderSide(color: Colors.orange.shade100)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.orange.shade700,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Waiting for $friendCode to accept...',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Colors.orange.shade900,
              ),
            ),
          ),
          GestureDetector(
            onTap: onCancel,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppConstants.textSecondary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
