import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../utils/constants.dart';

class SessionRelayService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  Function(String text)? onPartnerTranslationDraft;
  Function(String text)? onPartnerTranslationCompleted;
  Function(bool recording)? onPartnerRecordingState;
  Function()? onSessionEnded;
  Function()? onPartnerDisconnected;

  Future<void> connect({
    required String sessionId,
    required String userId,
  }) async {
    final wsUrl = AppConstants.serverBaseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');

    _channel = IOWebSocketChannel.connect(
      Uri.parse('$wsUrl/ws/session?sessionId=$sessionId&userId=$userId'),
    );

    _subscription = _channel!.stream.listen(
      _handleMessage,
      onError: (e) {
        debugPrint('Session relay error: $e');
        onPartnerDisconnected?.call();
      },
      onDone: () {
        onPartnerDisconnected?.call();
      },
    );
  }

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      switch (data['type'] as String?) {
        case 'translation_draft':
          onPartnerTranslationDraft?.call(data['text'] as String);
          break;
        case 'translation_completed':
          onPartnerTranslationCompleted?.call(data['text'] as String);
          break;
        case 'recording_state':
          onPartnerRecordingState?.call(data['recording'] as bool);
          break;
        case 'session_ended':
          onSessionEnded?.call();
          break;
        case 'partner_disconnected':
          onPartnerDisconnected?.call();
          break;
      }
    } catch (e) {
      debugPrint('Session relay parse error: $e');
    }
  }

  void sendTranslationDraft(String text) {
    _send({'type': 'translation_draft', 'text': text});
  }

  void sendTranslationCompleted(String text) {
    _send({'type': 'translation_completed', 'text': text});
  }

  void sendRecordingState(bool recording) {
    _send({'type': 'recording_state', 'recording': recording});
  }

  void sendEndSession() {
    _send({'type': 'end_session'});
  }

  void _send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  Future<void> disconnect() async {
    _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }
}
