import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:crypto/crypto.dart';
import '../utils/constants.dart';

class UserService {
  static final UserService instance = UserService._();
  UserService._();

  static const _hardwareIdChannel =
      MethodChannel('com.silsigan.app/hardware_id');

  String? _userId;
  String? _friendCode;
  String? _authToken;
  String? _hardwareId;
  bool _initialized = false;

  String? get userId => _userId;
  String? get friendCode => _friendCode;
  String? get authToken => _authToken;
  bool get isInitialized => _initialized;

  String get _baseUrl => AppConstants.serverBaseUrl;

  Map<String, String> get _authHeaders => {
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      };

  Future<void> init() async {
    if (_initialized) return;

    // Read hardware ID first — survives app data clear (Android) and
    // uninstall/reinstall (iOS). Null on unsupported platforms / errors.
    _hardwareId = await _getHardwareId();

    _userId = await _getStableDeviceId();

    final prefs = await SharedPreferences.getInstance();
    _friendCode = prefs.getString('friend_code');
    _authToken = prefs.getString('auth_token');

    // Invalidate token if userId changed (e.g., upgrade from old device ID logic)
    final storedUserId = prefs.getString('auth_user_id');
    if (storedUserId != null && storedUserId != _userId) {
      debugPrint(
          'UserService: userId changed ($storedUserId → $_userId), clearing stale token');
      _authToken = null;
      await prefs.remove('auth_token');
      await prefs.remove('auth_user_id');
    }

    if (_friendCode == null) {
      await _generateFriendCode();
    }

    // Auto-register if no auth token
    if (_authToken == null) {
      await _register();
    } else {
      // Existing users with a valid token: ensure hardwareId is linked to
      // their account on the server (one-time migration, idempotent).
      _linkHardwareIfNeeded();
    }

    // Sync friend code on every launch (fire-and-forget)
    if (_userId != null && _friendCode != null) {
      _syncFriendCode();
    }

    _initialized = true;
    debugPrint(
        'UserService: init complete, userId=$_userId, hasToken=${_authToken != null}, hasHardwareId=${_hardwareId != null}');
  }

  Future<String?> _getHardwareId() async {
    try {
      if (kIsWeb) return null;
      if (Platform.isAndroid) {
        return await _hardwareIdChannel.invokeMethod<String>('getAndroidId');
      } else if (Platform.isIOS) {
        return await _hardwareIdChannel.invokeMethod<String>('getKeychainId');
      }
    } catch (e) {
      debugPrint('Hardware ID lookup failed: $e');
    }
    return null;
  }

  Future<void> _register() async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/user/register'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'userId': _userId,
              'friendCode': _friendCode,
              if (_hardwareId != null) 'hardwareId': _hardwareId,
            }),
          )
          .timeout(const Duration(seconds: 30));
      debugPrint('Register response: ${response.statusCode}');
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['token'] != null) {
          _authToken = data['token'] as String;
          // Server may resolve a different canonical userId when it matches
          // our hardwareId to an existing account (e.g. after data clear).
          // Adopt whatever the server returned so subsequent calls target it.
          final resolvedUserId = data['userId'] as String?;
          if (resolvedUserId != null && resolvedUserId.isNotEmpty) {
            _userId = resolvedUserId;
          }
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('auth_token', _authToken!);
          await prefs.setString('auth_user_id', _userId!);
          // Mark hardware as synced so we don't redundantly call link-hardware
          if (_hardwareId != null) {
            await prefs.setBool('hardware_id_synced', true);
          }
        }
      }
    } catch (e) {
      debugPrint('Register error: $e');
    }
  }

  /// Fire-and-forget: links the device's hardwareId to the current user's
  /// server row, if not already synced. Used by existing users with a valid
  /// token who never went through the updated /register flow. Idempotent.
  Future<void> _linkHardwareIfNeeded() async {
    if (_hardwareId == null || _userId == null || _authToken == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('hardware_id_synced') == true) return;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/user/link-hardware'),
            headers: _authHeaders,
            body: json.encode({
              'userId': _userId,
              'hardwareId': _hardwareId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        await prefs.setBool('hardware_id_synced', true);
        debugPrint('UserService: hardware ID linked to server');
      } else {
        debugPrint('Link hardware failed: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      debugPrint('Link hardware error: $e');
    }
  }

  /// Ensure we have a valid auth token. If not, try to register.
  Future<void> ensureAuthenticated() async {
    if (_authToken != null) return;
    if (_userId == null) return;
    await _register();
  }

  /// Clear current token and re-register. Used when server returns 401.
  Future<void> refreshToken() async {
    debugPrint('UserService: refreshing token (old one invalid)');
    _authToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('auth_user_id');
    await _register();
  }

  Future<void> _generateFriendCode() async {
    final random = Random();
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    _friendCode =
        List.generate(8, (_) => chars[random.nextInt(chars.length)]).join();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('friend_code', _friendCode!);
  }

  Future<String> _getStableDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? uniqueId = prefs.getString('device_unique_id');

    if (uniqueId == null) {
      try {
        // Prefer hardware ID (ANDROID_ID / iOS keychain UUID) so the userId
        // stays stable across app data clear and uninstall/reinstall. Falls
        // back to platform-specific defaults if the platform channel failed.
        if (_hardwareId != null && _hardwareId!.isNotEmpty) {
          uniqueId = _hardwareId!;
        } else if (!kIsWeb && Platform.isAndroid) {
          // Fallback: random UUID — Build.ID is NOT unique per device
          uniqueId =
              '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(999999999)}';
        } else if (!kIsWeb && Platform.isIOS) {
          final deviceInfo = DeviceInfoPlugin();
          final iosInfo = await deviceInfo.iosInfo;
          uniqueId =
              iosInfo.identifierForVendor ?? DateTime.now().toIso8601String();
        } else {
          uniqueId = DateTime.now().toIso8601String();
        }
      } catch (e) {
        debugPrint('Error getting device ID: $e');
        uniqueId = 'fallback-${DateTime.now().millisecondsSinceEpoch}';
      }
      await prefs.setString('device_unique_id', uniqueId);
    }

    final bytes = utf8.encode(uniqueId);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 32);
  }

  /// Fire-and-forget activity ping to server.
  void reportActivity(String event, [Map<String, dynamic>? meta]) {
    if (_userId == null) return;
    final body = <String, dynamic>{'userId': _userId, 'event': event};
    if (meta != null) body['meta'] = meta;
    http
        .post(
          Uri.parse('$_baseUrl/api/user/activity'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode(body),
        )
        .timeout(const Duration(seconds: 10))
        .catchError((_) => http.Response('', 500));
  }

  Future<void> _syncFriendCode() async {
    try {
      await http.post(
        Uri.parse('$_baseUrl/api/user/sync-friend-code'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'userId': _userId, 'friendCode': _friendCode}),
      );
    } catch (e) {
      debugPrint('Sync friend code error: $e');
    }
  }

  // ==================
  // Usage tracking
  // ==================

  /// Fetch current usage from server. Returns {usedSeconds, limitMinutes, isPrivate}.
  Future<Map<String, dynamic>?> fetchUsage() async {
    if (_userId == null) return null;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/user/usage'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'userId': _userId}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'usedSeconds': (data['used_seconds'] as num).toInt(),
          'limitMinutes': (data['limit_minutes'] as num).toInt(),
          'isPrivate': data['is_private'] == true,
        };
      }
      return null;
    } catch (e) {
      debugPrint('Fetch usage error: $e');
      return null;
    }
  }

  /// Redeem a premium code. Returns {success, addedMinutes, usedSeconds, limitMinutes} or error string.
  Future<Map<String, dynamic>> redeemCode(String code) async {
    if (_userId == null) return {'error': 'Not authenticated'};
    try {
      await ensureAuthenticated();
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/user/redeem-code'),
            headers: _authHeaders,
            body: json.encode({'userId': _userId, 'code': code.trim()}),
          )
          .timeout(const Duration(seconds: 10));
      final data = json.decode(response.body);
      if (response.statusCode == 200) {
        return {
          'success': true,
          'addedMinutes': (data['added_minutes'] as num).toInt(),
          'usedSeconds': (data['used_seconds'] as num).toInt(),
          'limitMinutes': (data['limit_minutes'] as num).toInt(),
        };
      } else if (response.statusCode == 404) {
        return {'error': 'Invalid code'};
      } else if (response.statusCode == 409) {
        return {'error': 'Code already used'};
      }
      return {'error': data['error'] ?? 'Unknown error'};
    } catch (e) {
      debugPrint('Redeem code error: $e');
      return {'error': 'Network error'};
    }
  }

  // ==================
  // Friend operations
  // ==================

  Future<Map<String, dynamic>?> lookupByFriendCode(String code) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/user/by-code/${code.toUpperCase()}'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('Lookup error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> sendFriendRequest(String friendId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/friends/add'),
        headers: _authHeaders,
        body: json.encode({'userId': _userId, 'friendId': friendId}),
      );
      return json.decode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Send friend request error: $e');
      return null;
    }
  }

  Future<bool> acceptFriendRequest(String requesterId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/friends/accept'),
        headers: _authHeaders,
        body: json.encode({'userId': _userId, 'requesterId': requesterId}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Accept error: $e');
      return false;
    }
  }

  Future<bool> declineFriendRequest(String requesterId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/friends/decline'),
        headers: _authHeaders,
        body: json.encode({'userId': _userId, 'requesterId': requesterId}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Decline error: $e');
      return false;
    }
  }

  Future<bool> cancelFriendRequest(String friendId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/friends/cancel'),
        headers: _authHeaders,
        body: json.encode({'userId': _userId, 'friendId': friendId}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Cancel error: $e');
      return false;
    }
  }

  Future<bool> removeFriend(String friendId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/friends/remove'),
        headers: _authHeaders,
        body: json.encode({'userId': _userId, 'friendId': friendId}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Remove error: $e');
      return false;
    }
  }

  // ==================
  // Session invite operations
  // ==================

  Future<Map<String, dynamic>?> sendSessionInvite(
      String toUserId, String fromLanguage) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/session/invite'),
        headers: _authHeaders,
        body: json.encode({
          'userId': _userId,
          'toUserId': toUserId,
          'fromLanguage': fromLanguage,
        }),
      );
      return json.decode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Send session invite error: $e');
      return null;
    }
  }

  Future<bool> cancelSessionInvite(int inviteId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/session/cancel-invite'),
        headers: _authHeaders,
        body: json.encode({'userId': _userId, 'inviteId': inviteId}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Cancel session invite error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> acceptSessionInvite(
      int inviteId, String toLanguage) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/session/accept-invite'),
        headers: _authHeaders,
        body: json.encode({
          'userId': _userId,
          'inviteId': inviteId,
          'toLanguage': toLanguage,
        }),
      );
      return json.decode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Accept session invite error: $e');
      return null;
    }
  }

  Future<bool> rejectSessionInvite(int inviteId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/session/reject-invite'),
        headers: _authHeaders,
        body: json.encode({'userId': _userId, 'inviteId': inviteId}),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Reject session invite error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> getIncomingInvite() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/session/pending/$_userId'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return data['invite'] as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      debugPrint('Get incoming invite error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getInviteStatus(int inviteId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/session/status/$inviteId'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('Get invite status error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> listFriends() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/friends/$_userId'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return {'friends': [], 'incoming': [], 'outgoing': []};
    } catch (e) {
      debugPrint('List friends error: $e');
      return {'friends': [], 'incoming': [], 'outgoing': []};
    }
  }
}
