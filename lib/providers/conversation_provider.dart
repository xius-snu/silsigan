import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'target_language_provider.dart';

enum ConversationSpeaker { bottom, top }

class ConversationMessage {
  final ConversationSpeaker speaker;
  final String originalText;
  final String translatedText;

  const ConversationMessage({
    required this.speaker,
    required this.originalText,
    this.translatedText = '',
  });

  ConversationMessage copyWith({String? translatedText}) {
    return ConversationMessage(
      speaker: speaker,
      originalText: originalText,
      translatedText: translatedText ?? this.translatedText,
    );
  }
}

/// Which side is currently recording (null = nobody)
final activeConversationSpeakerProvider =
    StateProvider<ConversationSpeaker?>((ref) => null);

/// Completed conversation messages
final conversationMessagesProvider =
    StateProvider<List<ConversationMessage>>((ref) => []);

/// Live draft text (original) while someone is speaking
final conversationDraftOriginalProvider =
    StateProvider<String>((ref) => '');

/// Live draft text (translation) while someone is speaking
final conversationDraftTranslatedProvider =
    StateProvider<String>((ref) => '');

/// Bottom person's language (defaults to Korean)
final myLanguageProvider =
    StateProvider<TargetLanguage>((ref) => TargetLanguage.korean);

/// Top person's language (defaults to Vietnamese)
final theirLanguageProvider =
    StateProvider<TargetLanguage>((ref) => TargetLanguage.vietnamese);
