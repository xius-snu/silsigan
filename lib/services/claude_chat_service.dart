import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';
import 'user_service.dart';

class LearnMessage {
  final String role; // 'user' | 'assistant'
  final String text;
  String? explanation;
  bool explainLoading;

  LearnMessage({
    required this.role,
    required this.text,
    this.explanation,
    this.explainLoading = false,
  });

  Map<String, dynamic> toApi() => {'role': role, 'content': text};
}

/// Talks to our server proxy (Render) — never to api.anthropic.com directly.
/// Server attaches the Claude key, deducts 1 minute per roundtrip, and returns
/// the assistant's reply.
class ClaudeChatService {
  String get _baseUrl => AppConstants.serverBaseUrl;

  Map<String, String> get _headers {
    final token = UserService.instance.authToken;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Send conversation history and return the assistant's reply text.
  /// Throws on non-200 with the server's error message.
  Future<String> sendMessage({
    required List<LearnMessage> history,
    required String speakingLang,
    required String nativeLang,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/api/learn/message'),
      headers: _headers,
      body: jsonEncode({
        'userId': UserService.instance.userId,
        'speaking_language': speakingLang,
        'native_language': nativeLang,
        'messages': history.map((m) => m.toApi()).toList(),
      }),
    );

    if (res.statusCode != 200) {
      throw _ServerError.fromResponse(res);
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['reply'] as String).trim();
  }

  /// Ask Claude to explain [messageText] in the user's native language.
  Future<String> explain({
    required String messageText,
    required String speakingLang,
    required String nativeLang,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/api/learn/explain'),
      headers: _headers,
      body: jsonEncode({
        'userId': UserService.instance.userId,
        'speaking_language': speakingLang,
        'native_language': nativeLang,
        'text': messageText,
      }),
    );

    if (res.statusCode != 200) {
      throw _ServerError.fromResponse(res);
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['explanation'] as String).trim();
  }
}

class _ServerError implements Exception {
  final int status;
  final String message;
  _ServerError(this.status, this.message);

  factory _ServerError.fromResponse(http.Response res) {
    String message = 'Server error ${res.statusCode}';
    try {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['error'] is String) message = data['error'] as String;
    } catch (_) {}
    return _ServerError(res.statusCode, message);
  }

  @override
  String toString() => message;
}
