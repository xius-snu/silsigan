import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/claude_chat_service.dart';

/// Learn-mode chat history. Ephemeral — never persisted to sqflite.
final learnMessagesProvider =
    StateProvider<List<LearnMessage>>((ref) => <LearnMessage>[]);

/// True while waiting on a Claude reply.
final learnLoadingProvider = StateProvider<bool>((ref) => false);

/// Auto-play TTS on each assistant reply.
final learnAutoTtsProvider = StateProvider<bool>((ref) => true);

Future<bool> loadSavedLearnAutoTts() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('learn_auto_tts') ?? true;
}

Future<void> saveLearnAutoTts(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('learn_auto_tts', value);
}
