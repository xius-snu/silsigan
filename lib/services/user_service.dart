import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:crypto/crypto.dart';
import '../utils/constants.dart';

class UserService {
  static final UserService instance = UserService._();
  UserService._();

  String? _userId;
  String? _friendCode;
  String? _authToken;
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

    _userId = await _getStableDeviceId();

    final prefs = await SharedPreferences.getInstance();
    _friendCode = prefs.getString('friend_code');
    _authToken = prefs.getString('auth_token');

    if (_friendCode == null) {
      await _generateFriendCode();
    }

    // Auto-register if no auth token
    if (_authToken == null) {
      await _register();
    }

    // Sync friend code on every launch (fire-and-forget)
    if (_userId != null && _friendCode != null) {
      _syncFriendCode();
    }

    _initialized = true;
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
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['token'] != null) {
          _authToken = data['token'] as String;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('auth_token', _authToken!);
        }
      }
    } catch (e) {
      debugPrint('Register error: $e');
    }
  }

  /// Ensure we have a valid auth token. If not, try to register.
  Future<void> ensureAuthenticated() async {
    if (_authToken != null) return;
    if (_userId == null) return;
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
        if (!kIsWeb && Platform.isAndroid) {
          // Generate a random UUID — Build.ID is NOT unique per device
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
