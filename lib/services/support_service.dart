import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/support_message.dart';
import '../utils/constants.dart';
import 'user_service.dart';

/// Thrown when the server rejects a request with a user-facing reason.
class SupportException implements Exception {
  final String message;
  final int statusCode;
  const SupportException(this.message, this.statusCode);
  @override
  String toString() => message;
}

/// HTTP client for the in-app support chat.
///
/// Every call authenticates as [UserService.userId] — the shared account row
/// when signed in, this device otherwise — so a thread follows the same
/// identity as the user's time balance and saved recordings.
class SupportService {
  static final SupportService instance = SupportService._();
  SupportService._();

  static const _isAdminPrefKey = 'support_is_admin';

  String get _baseUrl => AppConstants.serverBaseUrl;

  /// Unread replies (customer) or threads awaiting a reply (team). Updated by
  /// [refreshStatus] and by the chat screens as they read; the purchase
  /// sheet's Contact Support button shows a dot while this is non-zero.
  final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);

  /// Whether this identity is on the support team. Cached across launches
  /// so the entry point can open straight into the inbox without a flash of
  /// the customer view; the server re-confirms on every thread fetch.
  bool? _isAdmin;
  bool? get isAdminCached => _isAdmin;

  /// True once the server has reported that push is configured on its side.
  bool pushEnabledOnServer = false;

  Future<void> loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_isAdminPrefKey)) {
      _isAdmin = prefs.getBool(_isAdminPrefKey);
    }
  }

  Future<void> _rememberIsAdmin(bool value) async {
    if (_isAdmin == value) return;
    _isAdmin = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isAdminPrefKey, value);
  }

  /// Identity changed (sign-in / sign-out): the cached role belongs to the
  /// previous row and the unread count is meaningless until refetched.
  Future<void> resetForIdentityChange() async {
    _isAdmin = null;
    unreadCount.value = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_isAdminPrefKey);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (UserService.instance.authToken != null)
          'Authorization': 'Bearer ${UserService.instance.authToken}',
      };

  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await UserService.instance.ensureAuthenticated();
    final userId = UserService.instance.userId;
    if (userId == null || UserService.instance.authToken == null) return null;
    final payload = json.encode({'userId': userId, ...body});

    var response = await http
        .post(Uri.parse('$_baseUrl$path'), headers: _headers, body: payload)
        .timeout(timeout);
    if (response.statusCode == 401) {
      await UserService.instance.refreshToken();
      if (UserService.instance.authToken == null) return null;
      // The identity may have changed under us (account token died and the
      // device fell back to its own row) — re-encode with the current id.
      final retryPayload = json.encode({
        'userId': UserService.instance.userId,
        ...body,
      });
      response = await http
          .post(Uri.parse('$_baseUrl$path'),
              headers: _headers, body: retryPayload)
          .timeout(timeout);
    }
    if (response.statusCode == 200) {
      final decoded = json.decode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    }
    String message = 'Something went wrong';
    try {
      final decoded = json.decode(response.body);
      if (decoded is Map && decoded['error'] is String) {
        message = decoded['error'] as String;
      }
    } catch (_) {}
    throw SupportException(message, response.statusCode);
  }

  /// `{isAdmin, unread}` — cheap enough to call whenever the purchase sheet
  /// opens or the app resumes. Swallows errors: a badge is never worth a
  /// snackbar.
  Future<void> refreshStatus() async {
    try {
      final data = await _post('/api/support/status', const {},
          timeout: const Duration(seconds: 10));
      if (data == null) return;
      await _rememberIsAdmin(data['isAdmin'] == true);
      unreadCount.value = (data['unread'] as num?)?.toInt() ?? 0;
      pushEnabledOnServer = data['pushEnabled'] == true;
    } catch (e) {
      debugPrint('Support status error: $e');
    }
  }

  /// Messages after [afterId] in the caller's own thread, or in [customerId]'s
  /// thread when the caller is on the team. Marks them read unless told not to.
  Future<SupportThreadPage?> fetchThread({
    String? customerId,
    int afterId = 0,
    bool markRead = true,
  }) async {
    final data = await _post('/api/support/thread', {
      if (customerId != null) 'customerId': customerId,
      'afterId': afterId,
      'markRead': markRead,
    });
    if (data == null) return null;
    final isAdmin = data['isAdmin'] == true;
    await _rememberIsAdmin(isAdmin);
    final messages = (data['messages'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SupportMessage.fromJson)
        .toList();
    final customerJson = data['customer'];
    return SupportThreadPage(
      isAdmin: isAdmin,
      messages: messages,
      customer: customerJson is Map<String, dynamic>
          ? SupportCustomer.fromJson(customerJson)
          : null,
    );
  }

  /// Post [text]. [clientId] makes a retry idempotent — the server returns the
  /// original message instead of storing a second copy.
  Future<SupportMessage?> send({
    required String text,
    required String clientId,
    String? customerId,
  }) async {
    final data = await _post(
        '/api/support/send',
        {
          if (customerId != null) 'customerId': customerId,
          'text': text,
          'clientId': clientId,
        },
        timeout: const Duration(seconds: 20));
    if (data == null) return null;
    final message = data['message'];
    if (message is! Map<String, dynamic>) return null;
    return SupportMessage.fromJson(message);
  }

  /// Team inbox, newest activity first.
  Future<List<SupportThreadSummary>?> fetchThreads() async {
    final data = await _post('/api/support/threads', const {});
    if (data == null) return null;
    return (data['threads'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SupportThreadSummary.fromJson)
        .toList();
  }

  /// Bind an FCM token to the current identity. Re-run on sign-in/out — the
  /// server keys rows by token, so the row just moves to the new user id.
  Future<bool> registerPushToken(String token, String platform) async {
    try {
      final data = await _post(
          '/api/support/push-token',
          {
            'token': token,
            'platform': platform,
          },
          timeout: const Duration(seconds: 10));
      if (data == null) return false;
      pushEnabledOnServer = data['pushEnabled'] == true;
      return data['ok'] == true;
    } catch (e) {
      debugPrint('Push token register error: $e');
      return false;
    }
  }
}
