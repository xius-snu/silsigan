// Regression tests for "after 30-40 min the session stops and shows 'A
// transcription error occurred' over and over" (desktop, 1.1.4).
//
// Measured against the live Soniox API (2026-10-08):
//  * 20 s with neither audio nor a keepalive -> 408 request_timeout + close.
//    Speaker capture that goes quiet, or a mic that dies, hit this on every
//    reconnect, 20 s apart, for as long as the gap lasted.
//  * context over 8,000 tokens -> 400 "Context is too long". The replayed
//    transcript grows through a session, so once a rotation crossed the limit
//    every reconnect was refused identically.
//  * The retry counter reset on the WebSocket upgrade, before Soniox (or the
//    proxy's credential check) had answered, so refusals retried ~every second.
//
// A local WebSocket server stands in for the proxy + Soniox.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:silsigan/services/soniox_realtime_service.dart';

class _Conn {
  _Conn(this.ws, this.query);

  final WebSocket ws;
  final Map<String, String> query;
  Map<String, dynamic>? config;
  final controls = <Map<String, dynamic>>[];
  int audioBytes = 0;

  String? get contextText =>
      (config?['context'] as Map<String, dynamic>?)?['text'] as String?;

  void sendError(int code, String type, String message) {
    ws.add(jsonEncode({
      'error_code': code,
      'error_type': type,
      'error_message': message,
    }));
    ws.close(1000);
  }

  void sendEmptyResponse() => ws.add(jsonEncode({'tokens': []}));
}

class _FakeProxy {
  late HttpServer _server;
  final connections = <_Conn>[];
  void Function(_Conn conn)? onConfig;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      final conn = _Conn(ws, req.uri.queryParameters);
      connections.add(conn);
      ws.listen((data) {
        if (data is String) {
          final msg = jsonDecode(data) as Map<String, dynamic>;
          if (conn.config == null) {
            conn.config = msg;
            onConfig?.call(conn);
          } else {
            conn.controls.add(msg);
          }
        } else {
          conn.audioBytes += (data as List<int>).length;
        }
      });
    });
  }

  String get url => 'ws://127.0.0.1:${_server.port}/ws/soniox-limited';

  Future<void> close() => _server.close(force: true);
}

Future<void> _waitFor(bool Function() done,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('boundedContext', () {
    test('a short context is sent whole', () {
      expect(SonioxRealtimeService.boundedContext('  hello there  '),
          'hello there');
      expect(SonioxRealtimeService.boundedContext(null), isNull);
    });

    test('a long context keeps only the tail, from a word boundary', () {
      final words = List.generate(3000, (i) => 'word$i').join(' ');
      final out = SonioxRealtimeService.boundedContext(words)!;
      expect(
          out.length, lessThanOrEqualTo(SonioxRealtimeService.maxContextChars));
      expect(words.endsWith(out), isTrue);
      expect(out, startsWith('word'));
    });

    test('Chinese stays inside Soniox token limit (about 1 token a char)', () {
      final zh = '今天我们在会议上详细讨论了下个季度的计划和预算问题。' * 1000;
      final out = SonioxRealtimeService.boundedContext(zh)!;
      expect(out.length, SonioxRealtimeService.maxContextChars);
      expect(SonioxRealtimeService.maxContextChars, lessThan(8000));
    });

    test('never opens on the second half of a surrogate pair', () {
      final emoji = '${'😀' * 2000}a';
      final out = SonioxRealtimeService.boundedContext(emoji)!;
      final first = out.codeUnitAt(0);
      expect(first >= 0xDC00 && first <= 0xDFFF, isFalse);
    });
  });

  group('SonioxRealtimeService against a fake proxy', () {
    late _FakeProxy proxy;
    late SonioxRealtimeService service;

    setUp(() async {
      proxy = _FakeProxy();
      await proxy.start();
      service = SonioxRealtimeService()
        ..proxyUrlOverride = proxy.url
        ..userId = 'u1'
        ..authToken = 't1';
    });

    tearDown(() async {
      await service.disconnect();
      await proxy.close();
    });

    test('an idle stream gets keepalives so Soniox never times it out',
        () async {
      proxy.onConfig = (conn) => conn.sendEmptyResponse();
      service.keepaliveIdle = const Duration(milliseconds: 200);
      await service.connect(targetLanguageCode: 'en');
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final keepalives = proxy.connections.single.controls
          .where((m) => m['type'] == 'keepalive');
      expect(keepalives.length, greaterThanOrEqualTo(2));
    });

    test('no keepalive while audio flows', () async {
      proxy.onConfig = (conn) => conn.sendEmptyResponse();
      service.keepaliveIdle = const Duration(milliseconds: 200);
      await service.connect(targetLanguageCode: 'en');
      final audio = Timer.periodic(const Duration(milliseconds: 50),
          (_) => service.sendAudio(Uint8List(4800)));
      await Future<void>.delayed(const Duration(milliseconds: 900));
      audio.cancel();
      final conn = proxy.connections.single;
      expect(conn.audioBytes, greaterThan(0));
      expect(conn.controls.where((m) => m['type'] == 'keepalive'), isEmpty);
    });

    test('the transcript context sent to Soniox is bounded', () async {
      proxy.onConfig = (conn) => conn.sendEmptyResponse();
      service.contextText = '오늘 회의에서는 다음 분기 계획을 논의했습니다. ' * 1000;
      await service.connect(targetLanguageCode: 'en');
      await _waitFor(() =>
          proxy.connections.isNotEmpty &&
          proxy.connections.single.config != null);
      final text = proxy.connections.single.contextText!;
      expect(text.length,
          lessThanOrEqualTo(SonioxRealtimeService.maxContextChars));
      expect(service.contextText!.trim().endsWith(text), isTrue);
    });

    test('a refused config is retried without the context, quietly', () async {
      proxy.onConfig = (conn) {
        if (conn.contextText != null) {
          conn.sendError(400, 'invalid_request',
              'Context is too long: 10589 tokens, the maximum is 8000 tokens.');
        } else {
          conn.sendEmptyResponse();
        }
      };
      final errors = <String>[];
      final reconnecting = <bool>[];
      final diagnostics = <String>[];
      service
        ..reconnectBaseDelay = const Duration(milliseconds: 10)
        ..contextText = 'the previous line of the transcript'
        ..onError = errors.add
        ..onReconnectingChanged = reconnecting.add
        ..onDiagnostic = (event, _) => diagnostics.add(event);
      await service.connect(targetLanguageCode: 'en');
      await _waitFor(() => reconnecting.length == 2);
      expect(proxy.connections.length, 2);
      expect(proxy.connections[0].contextText, isNotNull);
      expect(proxy.connections[1].contextText, isNull);
      expect(reconnecting, [true, false]);
      expect(errors, isEmpty);
      expect(diagnostics, contains('transcription_error'));
    });

    test('a session refused on sight backs off instead of hammering', () async {
      proxy.onConfig = (conn) => conn.sendError(
          503, 'service_unavailable', 'Cannot continue request (code 1).');
      final errors = <String>[];
      service
        ..reconnectBaseDelay = const Duration(milliseconds: 20)
        ..onError = errors.add;
      await service.connect(targetLanguageCode: 'en');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // 20, 40, 80, 160, 320, 600 ms (+-30%) between attempts: about seven
      // connects in 1.5 s. Resetting on the upgrade made it one per 20 ms.
      expect(proxy.connections.length, inInclusiveRange(4, 11));
      // Told once, after the third failed attempt, never per error.
      expect(errors, ['Transcription interrupted. Reconnecting…']);
    });

    test('a session that worked reconnects promptly after it drops', () async {
      proxy.onConfig = (conn) {
        conn.sendEmptyResponse();
        Timer(const Duration(milliseconds: 100), () => conn.ws.close(1000));
      };
      service.reconnectBaseDelay = const Duration(milliseconds: 50);
      await service.connect(targetLanguageCode: 'en');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // Each session proves itself before it drops, so every retry is a
      // first retry (~50 ms): about ten connects. Without the reset the
      // delays would grow (50, 100, 200, 400, 800 ms): about five.
      expect(proxy.connections.length, greaterThanOrEqualTo(7));
    });

    test('each reconnect presents the current credentials', () async {
      var token = 'old';
      proxy.onConfig = (conn) {
        if (conn.query['token'] == 'old') {
          conn.ws.close(4001, 'Invalid credentials');
        } else {
          conn.sendEmptyResponse();
        }
      };
      service
        ..reconnectBaseDelay = const Duration(milliseconds: 10)
        ..credentials = () => (userId: 'u1', token: token);
      await service.connect(targetLanguageCode: 'en');
      token = 'new';
      await _waitFor(() => proxy.connections.length >= 2);
      expect(proxy.connections[0].query['token'], 'old');
      expect(proxy.connections[1].query['token'], 'new');
    });

    test('the usage-limit close ends the session without reconnecting',
        () async {
      proxy.onConfig = (conn) => conn.ws.close(4005, 'Usage limit reached');
      var limitHits = 0;
      service
        ..reconnectBaseDelay = const Duration(milliseconds: 10)
        ..onUsageLimitReached = () => limitHits++;
      await service.connect(targetLanguageCode: 'en');
      await _waitFor(() => limitHits == 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(proxy.connections.length, 1);
      expect(service.isClosed, isTrue);
    });

    test('a throwing UI callback does not break the stream', () async {
      proxy.onConfig = (conn) {
        conn.ws.add(jsonEncode({
          'tokens': [
            {'text': 'hello', 'is_final': true},
            {'text': '<end>', 'is_final': true},
          ],
        }));
      };
      final errors = <String>[];
      final diagnostics = <String>[];
      service
        ..onError = errors.add
        ..onTranscriptionDraft = ((_) => throw StateError('ui bug'))
        ..onDiagnostic = (event, _) => diagnostics.add(event);
      await service.connect(targetLanguageCode: 'en');
      await _waitFor(
          () => diagnostics.contains('transcription_callback_error'));
      expect(errors, isEmpty);
      expect(proxy.connections.length, 1);
    });
  });
}
