import 'dart:async';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import '../firebase_options.dart';
import 'support_service.dart';

/// A support-chat push, either arriving while the app is open or tapped from
/// the notification shade.
class SupportPushEvent {
  /// The customer whose thread the message belongs to. For a customer this is
  /// their own id; for a team member it says which inbox thread to open.
  final String? threadUserId;
  final String? title;
  final String? body;

  const SupportPushEvent({this.threadUserId, this.title, this.body});
}

/// Firebase Cloud Messaging wrapper for the support chat.
///
/// Off until Firebase is configured: [init] uses [DefaultFirebaseOptions]
/// (iOS, Android, and macOS). Windows/Linux leave [isAvailable] false;
/// the support chat still works by polling.
class PushService {
  static final PushService instance = PushService._();
  PushService._();

  bool _available = false;
  bool get isAvailable => _available;

  String? _token;

  final _foreground = StreamController<SupportPushEvent>.broadcast();
  final _opened = StreamController<SupportPushEvent>.broadcast();

  /// A support message arrived while the app was in the foreground. The
  /// system shows nothing for these (see the presentation options in [init]);
  /// the UI decides whether to surface an in-app notice.
  Stream<SupportPushEvent> get onForegroundMessage => _foreground.stream;

  /// The user tapped a support notification while the app was in the
  /// background.
  Stream<SupportPushEvent> get onNotificationOpened => _opened.stream;

  /// Set when the app was launched *from* a notification tap; MainScreen
  /// consumes it after its first frame.
  SupportPushEvent? pendingOpen;

  static bool get _supportedPlatform =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid || Platform.isMacOS);

  Future<void> init() async {
    if (_available || !_supportedPlatform) return;
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e) {
      debugPrint('PushService: Firebase unavailable — push disabled ($e)');
      return;
    }
    _available = true;

    final messaging = FirebaseMessaging.instance;
    try {
      // Foreground arrivals are handled in-app (a chat that is already open
      // just refreshes; anywhere else shows a small in-app notice). A system
      // banner on top of that would double up.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: true,
        sound: false,
      );
    } catch (_) {}

    FirebaseMessaging.onMessage.listen((message) {
      final event = _eventFrom(message);
      if (event != null) _foreground.add(event);
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final event = _eventFrom(message);
      if (event != null) _opened.add(event);
    });
    try {
      final initial = await messaging.getInitialMessage();
      if (initial != null) pendingOpen = _eventFrom(initial);
    } catch (_) {}

    messaging.onTokenRefresh.listen((token) {
      _token = token;
      _registerToken(token);
    });

    // Don't block launch on the token round-trip.
    unawaited(syncToken());
  }

  SupportPushEvent? _eventFrom(RemoteMessage message) {
    final data = message.data;
    if (data['type'] != 'support') return null;
    return SupportPushEvent(
      threadUserId: data['threadUserId'] as String?,
      title: message.notification?.title ?? data['title'],
      body: message.notification?.body ?? data['body'],
    );
  }

  /// Fetch the FCM token and bind it to the current identity. Call again
  /// after sign-in / sign-out so the server moves the token to the new row.
  Future<void> syncToken() async {
    if (!_available) return;
    final messaging = FirebaseMessaging.instance;
    // iOS/macOS: getToken() throws until Apple has delivered an APNs token.
    // Wait for that explicitly — a blind getToken retry often expires first.
    if (Platform.isIOS || Platform.isMacOS) {
      String? apns;
      for (var attempt = 0; attempt < 6; attempt++) {
        try {
          apns = await messaging.getAPNSToken();
        } catch (e) {
          debugPrint('PushService: getAPNSToken attempt $attempt failed: $e');
        }
        if (apns != null) break;
        await Future.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
      if (apns == null) {
        debugPrint('PushService: no APNs token — FCM token not registered');
        return;
      }
    }
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final token = await messaging.getToken();
        if (token != null) {
          _token = token;
          await _registerToken(token);
          return;
        }
      } catch (e) {
        debugPrint('PushService: getToken attempt $attempt failed: $e');
      }
      await Future.delayed(Duration(seconds: 2 + attempt * 2));
    }
  }

  Future<void> _registerToken(String token) async {
    await SupportService.instance.registerPushToken(
      token,
      Platform.operatingSystem,
    );
  }

  /// Whether the OS currently lets us show notifications.
  Future<bool> isPermissionGranted() async {
    if (!_available) return false;
    try {
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      return _granted(settings);
    } catch (_) {
      return false;
    }
  }

  /// Ask for notification permission. Best called when the user has just
  /// done something that makes a notification obviously useful (their first
  /// support message), not at launch.
  Future<bool> requestPermission() async {
    if (!_available) return false;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      final ok = _granted(settings);
      if (ok) await syncToken();
      return ok;
    } catch (e) {
      debugPrint('PushService: requestPermission failed: $e');
      return false;
    }
  }

  bool _granted(NotificationSettings settings) =>
      settings.authorizationStatus == AuthorizationStatus.authorized ||
      settings.authorizationStatus == AuthorizationStatus.provisional;

  String? get token => _token;
}
