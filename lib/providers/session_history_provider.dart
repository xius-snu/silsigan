import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/transcript_session.dart';
import '../services/database_service.dart';

final sessionHistoryProvider =
    FutureProvider<List<TranscriptSession>>((ref) async {
  return await DatabaseService.instance.getAllSessions();
});
