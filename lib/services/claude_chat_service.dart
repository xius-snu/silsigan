import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/constants.dart';
import 'user_service.dart';

enum GradeStatus { correct, incorrect, na }

class LearnMessage {
  final String role; // 'user' | 'assistant'
  final String text;
  String? explanation;
  bool explainLoading;

  /// Grade applied to USER messages only. null = not yet graded.
  GradeStatus? gradeStatus;

  /// Plain-text feedback in the user's native language. Set when
  /// gradeStatus == incorrect.
  String? gradeExplanation;

  LearnMessage({
    required this.role,
    required this.text,
    this.explanation,
    this.explainLoading = false,
    this.gradeStatus,
    this.gradeExplanation,
  });

  Map<String, dynamic> toApi() => {'role': role, 'content': text};
}

class GradeResult {
  final GradeStatus status;
  final String explanation;
  GradeResult(this.status, this.explanation);
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

  /// Grade the user's most recent message in [history] for relevance +
  /// language quality. Separate API call so it runs in parallel with
  /// sendMessage (and deducts its own minute).
  Future<GradeResult> grade({
    required List<LearnMessage> history,
    required String speakingLang,
    required String nativeLang,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/api/learn/grade'),
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
    final raw = (data['grade'] as String?) ?? 'n/a';
    final explanation = ((data['explanation'] as String?) ?? '').trim();
    final status = switch (raw) {
      'correct' => GradeStatus.correct,
      'incorrect' => GradeStatus.incorrect,
      _ => GradeStatus.na,
    };
    return GradeResult(status, explanation);
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
