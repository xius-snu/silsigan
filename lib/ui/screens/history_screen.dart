import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/session_history_provider.dart';
import '../../utils/constants.dart';
import '../widgets/session_card.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(sessionHistoryProvider);

    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      appBar: AppBar(
        backgroundColor: AppConstants.bgColor,
        title: const Text(
          'History',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: AppConstants.textPrimary,
          ),
        ),
      ),
      body: sessionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text(
            'Failed to load sessions',
            style: TextStyle(color: AppConstants.textSecondary.withOpacity(0.6)),
          ),
        ),
        data: (sessions) {
          if (sessions.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history,
                    size: 64,
                    color: AppConstants.textSecondary.withOpacity(0.2),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No saved sessions yet',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppConstants.textSecondary.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              return SessionCard(
                session: session,
                onTap: () {
                  Navigator.pushNamed(
                    context,
                    '/detail',
                    arguments: session.id,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
