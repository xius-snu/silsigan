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

/// Identity for the app. Two identities exist at once:
///
///  * the **device** identity — hardware-derived, created on first launch,
///    always present, and the thing the server authenticates account calls
///    against;
///  * the optional **account** identity — a server-side row (`acct_…`) shared
///    by every device signed into the same Google/Apple login.
///
/// [userId]/[authToken] resolve to the account when one is linked, so usage,
/// billing, purchases and cloud sessions all address the shared row without
/// any caller needing to know a login happened. [deviceUserId] stays available
/// for the account endpoints themselves.
class UserService {
  static final UserService instance = UserService._();
  UserService._();

  static const _hardwareIdChannel =
      MethodChannel('com.silsigan.app/hardware_id');

  String? _deviceUserId;
  String? _deviceToken;
  String? _friendCode;
  String? _hardwareId;
  bool _initialized = false;

  // Account (set once the user signs in with Google/Apple).
  String? _accountUserId;
  String? _accountToken;
  String? _accountProvider;
  String? _accountEmail;

  /// The id every usage/billing/session call should address — the shared
  /// account when signed in, this device otherwise.
  String? get userId => _accountUserId ?? _deviceUserId;

  /// This device's own id. Account endpoints authenticate as the device, since
  /// the account may not exist yet at link time.
  String? get deviceUserId => _deviceUserId;
  String? get deviceAuthToken => _deviceToken;

  String? get accountUserId => _accountUserId;
  String? get accountProvider => _accountProvider;
  String? get accountEmail => _accountEmail;
  bool get isAccountLinked => _accountUserId != null && _accountToken != null;

  /// The account's stable 8-char code. Historically the "friend code"
  /// (pref key + server field keep that name); now surfaced in the UI as the
  /// customer ID for support/purchase enquiries.
  String? get friendCode => _friendCode;
  String? get authToken => isAccountLinked ? _accountToken : _deviceToken;
  bool get isInitialized => _initialized;

  String get _baseUrl => AppConstants.serverBaseUrl;

  /// Headers that authenticate as the device rather than the account. Account
  /// endpoints (link/refresh/signout/ticket/poll) all use these.
  Map<String, String> get deviceAuthHeaders => {
        'Content-Type': 'application/json',
        if (_deviceToken != null) 'Authorization': 'Bearer $_deviceToken',
      };

  Future<void> init() async {
    if (_initialized) return;

    // Read hardware ID first — survives app data clear (Android) and
    // uninstall/reinstall (iOS). Null on unsupported platforms / errors.
    _hardwareId = await _getHardwareId();

    _deviceUserId = await _getStableDeviceId();

    final prefs = await SharedPreferences.getInstance();
    _friendCode = prefs.getString('friend_code');
    _deviceToken = prefs.getString('auth_token');

    // Invalidate token if userId changed (e.g., upgrade from old device ID logic)
    final storedUserId = prefs.getString('auth_user_id');
    if (storedUserId != null && storedUserId != _deviceUserId) {
      debugPrint(
          'UserService: userId changed ($storedUserId → $_deviceUserId), clearing stale token');
      _deviceToken = null;
      await prefs.remove('auth_token');
      await prefs.remove('auth_user_id');
    }

    if (_friendCode == null) {
      await _generateFriendCode();
    }

    // Auto-register if no auth token
    if (_deviceToken == null) {
      await _register();
    } else {
      // Existing users with a valid token: ensure hardwareId is linked to
      // their account on the server (one-time migration, idempotent).
      _linkHardwareIfNeeded();
    }

    _loadAccountFromPrefs(prefs);

    // Sync friend code on every launch (fire-and-forget)
    if (_deviceUserId != null && _friendCode != null) {
      _syncFriendCode();
    }

    _initialized = true;
    debugPrint(
        'UserService: init complete, deviceUserId=$_deviceUserId, hasToken=${_deviceToken != null}, hasHardwareId=${_hardwareId != null}, account=${_accountUserId ?? 'none'}');
  }

  Future<String?> _getHardwareId() async {
    try {
      if (kIsWeb) return null;
      if (Platform.isAndroid) {
        return await _hardwareIdChannel.invokeMethod<String>('getAndroidId');
      } else if (Platform.isIOS) {
        return await _hardwareIdChannel.invokeMethod<String>('getKeychainId');
      } else if (Platform.isWindows) {
        final info = await DeviceInfoPlugin().windowsInfo;
        final id = info.deviceId.trim();
        return id.isEmpty ? null : id;
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
              'userId': _deviceUserId,
              'friendCode': _friendCode,
              if (_hardwareId != null) 'hardwareId': _hardwareId,
            }),
          )
          .timeout(const Duration(seconds: 30));
      debugPrint('Register response: ${response.statusCode}');
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['token'] != null) {
          _deviceToken = data['token'] as String;
          // Server may resolve a different canonical userId when it matches
          // our hardwareId to an existing account (e.g. after data clear).
          // Adopt whatever the server returned so subsequent calls target it.
          final resolvedUserId = data['userId'] as String?;
          if (resolvedUserId != null && resolvedUserId.isNotEmpty) {
            _deviceUserId = resolvedUserId;
          }
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('auth_token', _deviceToken!);
          await prefs.setString('auth_user_id', _deviceUserId!);
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
    if (_hardwareId == null || _deviceUserId == null || _deviceToken == null) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('hardware_id_synced') == true) return;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/user/link-hardware'),
            headers: deviceAuthHeaders,
            body: json.encode({
              'userId': _deviceUserId,
              'hardwareId': _hardwareId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        await prefs.setBool('hardware_id_synced', true);
        debugPrint('UserService: hardware ID linked to server');
      } else {
        debugPrint(
            'Link hardware failed: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      debugPrint('Link hardware error: $e');
    }
  }

  /// Ensure we have a valid auth token. If not, try to register.
  Future<void> ensureAuthenticated() async {
    if (authToken != null) return;
    if (_deviceUserId == null) return;
    await _register();
  }

  /// Account endpoints authenticate as the device, so they need the device
  /// token specifically — [ensureAuthenticated] is satisfied by an account
  /// token those calls cannot present.
  Future<void> ensureDeviceAuthenticated() async {
    if (_deviceToken != null) return;
    if (_deviceUserId == null) return;
    await _register();
  }

  /// Clear current token and re-register. Used when server returns 401.
  ///
  /// While signed in, a 401 means the account token died (revoked, or the
  /// account row went away) — not that the device is unknown. Try to mint a
  /// fresh account token off the still-valid device token first, and only fall
  /// back to signing out locally when the server says this device is no longer
  /// a member.
  Future<void> refreshToken() async {
    if (isAccountLinked) {
      debugPrint('UserService: refreshing account token');
      if (await _refreshAccountToken()) return;
      // Device credentials may be the stale half — re-register and retry once.
      await _reregisterDevice();
      if (await _refreshAccountToken()) return;
      debugPrint('UserService: account no longer active, reverting to device');
      await clearAccount();
      return;
    }
    debugPrint('UserService: refreshing token (old one invalid)');
    await _reregisterDevice();
  }

  Future<void> _reregisterDevice() async {
    _deviceToken = null;
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
    final id = userId;
    if (id == null) return;
    final body = <String, dynamic>{'userId': id, 'event': event};
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
        body: json.encode({'userId': _deviceUserId, 'friendCode': _friendCode}),
      );
    } catch (e) {
      debugPrint('Sync friend code error: $e');
    }
  }

  // ==================
  // Account sync
  // ==================

  void _loadAccountFromPrefs(SharedPreferences prefs) {
    _accountUserId = prefs.getString('account_user_id');
    _accountToken = prefs.getString('account_token');
    _accountProvider = prefs.getString('account_provider');
    _accountEmail = prefs.getString('account_email');
  }

  /// Adopt an account returned by /api/account/link, /refresh or /poll.
  Future<void> applyAccount({
    required String accountUserId,
    required String token,
    String? provider,
    String? email,
  }) async {
    _accountUserId = accountUserId;
    _accountToken = token;
    if (provider != null) _accountProvider = provider;
    if (email != null) _accountEmail = email;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('account_user_id', accountUserId);
    await prefs.setString('account_token', token);
    if (_accountProvider != null) {
      await prefs.setString('account_provider', _accountProvider!);
    }
    if (_accountEmail != null) {
      await prefs.setString('account_email', _accountEmail!);
    }
    // A restored account is proof enough; skip the one-shot status probe.
    await prefs.setBool('account_status_checked', true);
  }

  /// Drop the account locally. The server-side membership (and the ledger that
  /// makes re-linking non-duplicating) is untouched — that is the job of
  /// /api/account/signout.
  Future<void> clearAccount() async {
    _accountUserId = null;
    _accountToken = null;
    _accountProvider = null;
    _accountEmail = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('account_user_id');
    await prefs.remove('account_token');
    await prefs.remove('account_provider');
    await prefs.remove('account_email');
  }

  // ==================
  // Usage tracking
  // ==================

  /// Fetch current usage from server. Returns {usedSeconds, limitMinutes, isPrivate}.
  Future<Map<String, dynamic>?> fetchUsage() async {
    final id = userId;
    if (id == null) return null;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/user/usage'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'userId': id}),
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

  Future<bool> _refreshAccountToken() async {
    if (_deviceUserId == null || _deviceToken == null) return false;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/account/refresh'),
            headers: deviceAuthHeaders,
            body: json.encode({'userId': _deviceUserId}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return false;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final token = data['token'] as String?;
      final accountId = data['accountUserId'] as String?;
      if (token == null || accountId == null) return false;
      await applyAccount(
        accountUserId: accountId,
        token: token,
        provider: data['provider'] as String?,
        email: data['email'] as String?,
      );
      return true;
    } catch (e) {
      debugPrint('Account refresh error: $e');
      return false;
    }
  }
}
