import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/transcript_session.dart';
import '../../providers/session_history_provider.dart';
import '../../services/database_service.dart';
import '../../utils/constants.dart';

class SessionDetailScreen extends ConsumerStatefulWidget {
  const SessionDetailScreen({super.key});

  @override
  ConsumerState<SessionDetailScreen> createState() =>
      _SessionDetailScreenState();
}

class _SessionDetailScreenState extends ConsumerState<SessionDetailScreen> {
  TranscriptSession? _session;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading) {
      final sessionId = ModalRoute.of(context)!.settings.arguments as int;
      _loadSession(sessionId);
    }
  }

  Future<void> _loadSession(int id) async {
    final session = await DatabaseService.instance.getSession(id);
    if (mounted) {
      setState(() {
        _session = session;
        _loading = false;
      });
    }
  }

  Future<void> _deleteSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Session'),
        content:
            const Text('Are you sure you want to delete this session?'),
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

    if (confirmed == true && _session?.id != null) {
      await DatabaseService.instance.deleteSession(_session!.id!);
      ref.invalidate(sessionHistoryProvider);
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }

  String _formatDate(String isoDate) {
    try {
      final dt = DateTime.parse(isoDate);
      final months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year} — $hour:$minute';
    } catch (_) {
      return isoDate;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppConstants.bgColor,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_session == null) {
      return Scaffold(
        backgroundColor: AppConstants.bgColor,
        appBar: AppBar(backgroundColor: AppConstants.bgColor),
        body: const Center(
          child: Text(
            'Session not found',
            style: TextStyle(color: AppConstants.textSecondary),
          ),
        ),
      );
    }

    final session = _session!;
    final koreanLines = session.koreanFull.split('\n');
    final vietnameseLines = session.vietnameseFull.split('\n');

    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      appBar: AppBar(
        backgroundColor: AppConstants.bgColor,
        title: Text(
          _formatDate(session.createdAt),
          style: const TextStyle(
            fontSize: 16,
            color: AppConstants.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteSession,
            tooltip: 'Delete',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppConstants.panelPaddingH),
              decoration: BoxDecoration(
                color: AppConstants.panelColor,
                borderRadius:
                    BorderRadius.circular(AppConstants.panelBorderRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TRANSCRIPTION',
                    style: TextStyle(
                      fontSize: AppConstants.labelFontSize,
                      fontWeight: FontWeight.w400,
                      color: AppConstants.textSecondary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...koreanLines.map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        line,
                        style: const TextStyle(
                          fontSize: AppConstants.contentFontSize,
                          color: AppConstants.textPrimary,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppConstants.panelPaddingH),
              decoration: BoxDecoration(
                color: AppConstants.panelColor,
                borderRadius:
                    BorderRadius.circular(AppConstants.panelBorderRadius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TRANSLATION',
                    style: TextStyle(
                      fontSize: AppConstants.labelFontSize,
                      fontWeight: FontWeight.w400,
                      color: AppConstants.textSecondary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...vietnameseLines.map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        line,
                        style: const TextStyle(
                          fontSize: AppConstants.contentFontSize,
                          color: AppConstants.textPrimary,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
