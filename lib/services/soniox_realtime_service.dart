import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../utils/constants.dart';

class SonioxRealtimeService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 3;
  bool _intentionallyClosed = false;
  static const _apiKey = String.fromEnvironment('SONIOX_API_KEY');

  // Transcription token state
  String _pendingUtterance = '';
  String _provisionalText = '';

  // Translation token state
  String _pendingTranslation = '';
  String _provisionalTranslation = '';

  // Stored for reconnect
  String? _targetLanguageCode;

  // Callbacks
  Function(String draft)? onTranscriptionDraft;
  Function(String transcript)? onTranscriptionCompleted;
  Function(String draft)? onTranslationDraft;
  Function(String translation)? onTranslationCompleted;
  Function(String error)? onError;
  Function()? onConnected;

  Future<void> connect({String? targetLanguageCode}) async {
    _intentionallyClosed = false;
    _reconnectAttempts = 0;
    _targetLanguageCode = targetLanguageCode;
    _resetTokenState();
    await _doConnect();
  }

  Future<void> _doConnect() async {
    try {
      _channel = IOWebSocketChannel.connect(
        Uri.parse(AppConstants.sonioxRealtimeUrl),
      );

      // Build config message
      final config = <String, dynamic>{
        'api_key': _apiKey,
        'model': AppConstants.sonioxModel,
        'language_hints': [AppConstants.transcriptionLanguage],
        'audio_format': AppConstants.audioFormat,
        'sample_rate': AppConstants.sampleRate,
        'num_channels': AppConstants.numChannels,
        'enable_endpoint_detection': true,
        'max_endpoint_delay_ms': AppConstants.endpointDelayMs,
      };

      // Add translation config if target is not the source language
      if (_targetLanguageCode != null &&
          _targetLanguageCode != AppConstants.transcriptionLanguage) {
        config['translation'] = {
          'type': 'one_way',
          'target_language': _targetLanguageCode,
        };
      }

      // Send config as first message (auth + session settings)
      _channel!.sink.add(jsonEncode(config));

      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (error) {
          onError?.call(error.toString());
          _tryReconnect();
        },
        onDone: () {
          if (!_intentionallyClosed) {
            _tryReconnect();
          }
        },
      );

      _reconnectAttempts = 0;
      onConnected?.call();
    } catch (e) {
      onError?.call(e.toString());
      _tryReconnect();
    }
  }

  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

      // Check for errors
      if (data['error_code'] != null) {
        final errorMsg =
            data['error_message'] as String? ?? 'Unknown Soniox error';
        onError?.call(errorMsg);
        return;
      }

      // Check for session finished
      if (data['finished'] == true) {
        return;
      }

      final tokens = data['tokens'] as List<dynamic>?;
      if (tokens == null || tokens.isEmpty) return;

      // Separate source and translation tokens
      final sourceTokens = <Map<String, dynamic>>[];
      final translationTokens = <Map<String, dynamic>>[];

      for (final token in tokens) {
        final status = token['translation_status'] as String?;
        if (status == 'translation') {
          translationTokens.add(token as Map<String, dynamic>);
        } else {
          // 'source', 'original', or null (no translation configured)
          sourceTokens.add(token as Map<String, dynamic>);
        }
      }

      // Process source tokens (transcription)
      if (sourceTokens.isNotEmpty) {
        _processSourceTokens(sourceTokens);
      }

      // Process translation tokens
      if (translationTokens.isNotEmpty) {
        _processTranslationTokens(translationTokens);
      }
    } catch (e) {
      onError?.call('Failed to parse message: $e');
    }
  }

  void _processSourceTokens(List<Map<String, dynamic>> tokens) {
    final hadProvisional = _provisionalText.isNotEmpty;
    String newProvisionalText = '';
    String newFinalText = '';

    for (final token in tokens) {
      final text = token['text'] as String? ?? '';
      final isFinal = token['is_final'] as bool? ?? false;

      if (text.startsWith('<') && text.endsWith('>')) continue;

      if (isFinal) {
        newFinalText += text;
      } else {
        newProvisionalText += text;
      }
    }

    _pendingUtterance += newFinalText;
    _provisionalText = newProvisionalText;

    onTranscriptionDraft?.call(_provisionalText);

    if (hadProvisional &&
        _provisionalText.isEmpty &&
        _pendingUtterance.isNotEmpty) {
      onTranscriptionCompleted?.call(_pendingUtterance.trim());
      _pendingUtterance = '';

      // Flush pending translation at source utterance boundary
      if (_pendingTranslation.isNotEmpty || _provisionalTranslation.isNotEmpty) {
        final fullTranslation =
            (_pendingTranslation + _provisionalTranslation).trim();
        if (fullTranslation.isNotEmpty) {
          onTranslationCompleted?.call(fullTranslation);
        }
        _pendingTranslation = '';
        _provisionalTranslation = '';
      }
    }
  }

  void _processTranslationTokens(List<Map<String, dynamic>> tokens) {
    final hadProvisional = _provisionalTranslation.isNotEmpty;
    String newProvisionalText = '';
    String newFinalText = '';

    for (final token in tokens) {
      final text = token['text'] as String? ?? '';
      final isFinal = token['is_final'] as bool? ?? false;

      if (text.startsWith('<') && text.endsWith('>')) continue;

      if (isFinal) {
        newFinalText += text;
      } else {
        newProvisionalText += text;
      }
    }

    _pendingTranslation += newFinalText;
    _provisionalTranslation = newProvisionalText;

    // Show accumulated translation in real-time (final + provisional)
    onTranslationDraft?.call(_pendingTranslation + _provisionalTranslation);
  }

  /// Send raw PCM audio bytes — no base64 encoding needed.
  void sendAudio(Uint8List audioBytes) {
    if (_channel == null) return;
    _channel!.sink.add(audioBytes);
  }

  /// Force-finalize any pending non-final tokens.
  /// Call this before disconnect when stopping recording.
  void finalize() {
    if (_channel == null) return;
    _channel!.sink.add(jsonEncode({'type': 'finalize'}));
  }

  void _tryReconnect() {
    if (_intentionallyClosed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      onError?.call(
          'Failed to reconnect after $_maxReconnectAttempts attempts');
      return;
    }
    _reconnectAttempts++;
    Future.delayed(const Duration(seconds: 1), () {
      if (!_intentionallyClosed) {
        _doConnect();
      }
    });
  }

  void _resetTokenState() {
    _pendingUtterance = '';
    _provisionalText = '';
    _pendingTranslation = '';
    _provisionalTranslation = '';
  }

  Future<void> disconnect() async {
    _intentionallyClosed = true;
    _subscription?.cancel();
    _subscription = null;

    // Flush any remaining pending utterance
    if (_pendingUtterance.isNotEmpty) {
      onTranscriptionCompleted?.call(_pendingUtterance.trim());
      _pendingUtterance = '';
    }

    // Flush any remaining pending translation
    if (_pendingTranslation.isNotEmpty) {
      onTranslationCompleted?.call(_pendingTranslation.trim());
      _pendingTranslation = '';
    }

    await _channel?.sink.close();
    _channel = null;
  }
}
