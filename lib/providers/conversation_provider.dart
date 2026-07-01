import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

/// Which side is currently speaking, auto-detected from the spoken language
/// while the shared two-way session is listening (null = nobody detected yet).
/// Drives which side shows the live draft bubble.
final activeConversationSpeakerProvider =
    StateProvider<ConversationSpeaker?>((ref) => null);

/// Whether Conversation mode speaks each completed translation aloud in the
/// listener's language. Defaults OFF — playing translations out loud on a
/// two-way session invites echo/feedback, so the user opts in (and is prompted
/// to use headphones first). Toggled via the speaker button in the header. Not
/// persisted.
final conversationTtsEnabledProvider = StateProvider<bool>((ref) => false);

/// Completed conversation messages
final conversationMessagesProvider =
    StateProvider<List<ConversationMessage>>((ref) => []);

/// True while the shared session is connecting (after the mic tap, before audio
/// starts streaming). Drives a "connecting" affordance on the mic so the tap
/// gives immediate feedback and stays cancellable.
final conversationConnectingProvider = StateProvider<bool>((ref) => false);

/// Live draft text (original) while someone is speaking
final conversationDraftOriginalProvider = StateProvider<String>((ref) => '');

/// Live draft text (translation) while someone is speaking
final conversationDraftTranslatedProvider = StateProvider<String>((ref) => '');

/// Bottom person's language (defaults to Korean)
final myLanguageProvider =
    StateProvider<TargetLanguage>((ref) => TargetLanguage.korean);

/// Top person's language (defaults to Vietnamese)
final theirLanguageProvider =
    StateProvider<TargetLanguage>((ref) => TargetLanguage.vietnamese);

/// Load saved conversation languages on app start
Future<({TargetLanguage my, TargetLanguage their})>
    loadSavedConversationLanguages() async {
  final prefs = await SharedPreferences.getInstance();
  final myCode = prefs.getString('conv_my_language');
  final theirCode = prefs.getString('conv_their_language');
  return (
    my: myCode != null
        ? TargetLanguage.fromCode(myCode)
        : TargetLanguage.korean,
    their: theirCode != null
        ? TargetLanguage.fromCode(theirCode)
        : TargetLanguage.vietnamese,
  );
}

/// Persist conversation language selection
Future<void> saveConversationLanguages(
    TargetLanguage my, TargetLanguage their) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('conv_my_language', my.code);
  await prefs.setString('conv_their_language', their.code);
}
