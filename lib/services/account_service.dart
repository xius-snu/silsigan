import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/constants.dart';
import '../utils/desktop.dart';
import 'purchase_service.dart';
import 'sync_service.dart';
import 'user_service.dart';

/// What the account UI shows. Mirrors what the server reports for this device.
@immutable
class AccountState {
  final bool linked;
  final String? email;

  /// 'google' | 'apple' — null when the server has no identity row yet.
  final String? provider;
  final int deviceCount;

  const AccountState({
    required this.linked,
    this.email,
    this.provider,
    this.deviceCount = 0,
  });

  static const signedOut = AccountState(linked: false);

  AccountState copyWith({String? email, String? provider, int? deviceCount}) =>
      AccountState(
        linked: linked,
        email: email ?? this.email,
        provider: provider ?? this.provider,
        deviceCount: deviceCount ?? this.deviceCount,
      );
}

/// Outcome of a sign-in attempt, so the sheet can tell "user backed out" from
/// "something broke" without parsing strings.
enum AccountResultKind { success, cancelled, notConfigured, failed }

@immutable
class AccountResult {
  final AccountResultKind kind;
  final String? message;

  /// Purchased minutes this device just folded into the account. Zero when the
  /// device had only its free allowance, or had already contributed before.
  final int addedMinutes;

  const AccountResult(this.kind, {this.message, this.addedMinutes = 0});

  bool get isSuccess => kind == AccountResultKind.success;
}

/// Optional Google/Apple sign-in that merges a device's time balance and cloud
/// history into a shared account.
///
/// Mobile uses the native account sheets. Desktop has no native SDK, so it
/// opens the system browser against the server's OAuth broker and polls for
/// the resulting token — same server endpoints, same merge, different front
/// door.
class AccountService {
  static final AccountService instance = AccountService._();
  AccountService._();

  /// Broadcasts sign-in changes. The restore probe below can land seconds
  /// after launch and silently repoints which server row the app addresses,
  /// so the screen needs a push rather than a one-time read.
  final ValueNotifier<AccountState> stateListenable =
      ValueNotifier<AccountState>(AccountState.signedOut);

  AccountState get state => stateListenable.value;
  void _setState(AccountState value) => stateListenable.value = value;

  bool _googleInitialized = false;

  /// Lets the sheet abandon a desktop browser sign-in the user walked away
  /// from, instead of holding the UI for the full polling window.
  bool _browserSignInCancelled = false;

  void cancelBrowserSignIn() => _browserSignInCancelled = true;

  String get _baseUrl => AppConstants.serverBaseUrl;

  /// Google sign-in needs client IDs baked in; without them the button would
  /// throw at tap time, so hide it instead. The two platforms want different
  /// ones: Android's Credential Manager authenticates against the *Web* client
  /// (as `serverClientId`), while iOS uses its own client ID.
  static bool get googleConfigured {
    if (kIsWeb) return false;
    if (Platform.isIOS || Platform.isMacOS) {
      return AppConstants.googleIosClientId.isNotEmpty;
    }
    return AppConstants.googleServerClientId.isNotEmpty;
  }

  /// Sign in with Apple is native on Apple platforms only. Android and Windows
  /// would need Apple's web flow (a Services ID plus a server-signed client
  /// secret), which Google sign-in already covers there.
  static bool get appleAvailable {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isMacOS;
  }

  /// Desktop falls back to the browser broker, which only exists for Google.
  static bool get usesBrowserFlow => isDesktopPlatform;

  /// Seeds [state] from whatever UserService restored out of SharedPreferences,
  /// then — once per install — asks the server whether this device is still an
  /// active member of an account we no longer hold a token for. That covers
  /// reinstall and Android data-clear, where the hardware ID resolves back to
  /// the same device row but local storage is empty. It is deliberately
  /// one-shot: signing out deactivates membership server-side, so a signed-out
  /// user is never silently signed back in.
  Future<void> restore() async {
    final user = UserService.instance;
    if (user.isAccountLinked) {
      _setState(AccountState(
        linked: true,
        email: user.accountEmail,
        provider: user.accountProvider,
        deviceCount: 1,
      ));
      unawaited(refreshStatus());
      return;
    }
    _setState(AccountState.signedOut);
    // Never awaited by the caller: this is two network round trips, and
    // blocking on them would push out the first frame for every user who has
    // never signed in. Listeners of [stateListenable] pick up the result.
    unawaited(_restoreProbe(user));
  }

  Future<void> _restoreProbe(UserService user) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('account_status_checked') == true) return;
    await prefs.setBool('account_status_checked', true);
    if (user.deviceUserId == null || user.deviceAuthToken == null) return;
    try {
      final status = await _postAsDevice('/api/account/status', {});
      if (status == null || status['linked'] != true) return;
      // Still a member — mint a token so this install rejoins silently.
      final refreshed = await _postAsDevice('/api/account/refresh', {});
      final token = refreshed?['token'] as String?;
      final accountId = refreshed?['accountUserId'] as String?;
      if (token == null || accountId == null) return;
      await user.applyAccount(
        accountUserId: accountId,
        token: token,
        provider: refreshed?['provider'] as String?,
        email: refreshed?['email'] as String?,
      );
      _setState(AccountState(
        linked: true,
        email: refreshed?['email'] as String?,
        provider: refreshed?['provider'] as String?,
        deviceCount: (refreshed?['deviceCount'] as num?)?.toInt() ?? 1,
      ));
      await _afterIdentityChange();
    } catch (e) {
      debugPrint('Account restore probe failed: $e');
    }
  }

  /// Refresh the signed-in device count / email shown in the sheet.
  Future<void> refreshStatus() async {
    if (!UserService.instance.isAccountLinked) {
      _setState(AccountState.signedOut);
      return;
    }
    final data = await _postAsDevice('/api/account/status', {});
    if (data == null) return;
    if (data['linked'] != true) {
      // Signed out from another device, or the account was removed.
      await UserService.instance.clearAccount();
      _setState(AccountState.signedOut);
      await _afterIdentityChange();
      return;
    }
    _setState(AccountState(
      linked: true,
      email: data['email'] as String? ?? state.email,
      provider: data['provider'] as String? ?? state.provider,
      deviceCount: (data['deviceCount'] as num?)?.toInt() ?? 1,
    ));
  }

  // ── Sign in ─────────────────────────────────────────────────────────

  Future<AccountResult> signInWithGoogle() async {
    if (usesBrowserFlow) return _signInWithBrowser();
    if (!googleConfigured) {
      return const AccountResult(AccountResultKind.notConfigured,
          message: 'Google sign-in is not configured in this build.');
    }
    try {
      final signIn = GoogleSignIn.instance;
      if (!_googleInitialized) {
        await signIn.initialize(
          clientId: AppConstants.googleIosClientId.isEmpty
              ? null
              : AppConstants.googleIosClientId,
          serverClientId: AppConstants.googleServerClientId.isEmpty
              ? null
              : AppConstants.googleServerClientId,
        );
        _googleInitialized = true;
      }
      if (!signIn.supportsAuthenticate()) {
        return _signInWithBrowser();
      }
      final account = await signIn.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        return const AccountResult(AccountResultKind.failed,
            message: 'Google did not return an identity token.');
      }
      return _link('google', idToken);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return const AccountResult(AccountResultKind.cancelled);
      }
      debugPrint('Google sign-in failed: ${e.code} ${e.description}');
      return AccountResult(AccountResultKind.failed,
          message: e.description ?? 'Google sign-in failed.');
    } catch (e) {
      debugPrint('Google sign-in error: $e');
      return const AccountResult(AccountResultKind.failed,
          message: 'Google sign-in failed.');
    }
  }

  Future<AccountResult> signInWithApple() async {
    if (!appleAvailable) {
      return const AccountResult(AccountResultKind.notConfigured,
          message: 'Sign in with Apple is not available on this device.');
    }
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [AppleIDAuthorizationScopes.email],
      );
      final idToken = credential.identityToken;
      if (idToken == null) {
        return const AccountResult(AccountResultKind.failed,
            message: 'Apple did not return an identity token.');
      }
      return _link('apple', idToken);
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        return const AccountResult(AccountResultKind.cancelled);
      }
      debugPrint('Apple sign-in failed: ${e.code} ${e.message}');
      return AccountResult(AccountResultKind.failed,
          message: e.message.isNotEmpty
              ? 'Sign in with Apple failed. ${e.message}'
              : 'Sign in with Apple failed.');
    } catch (e) {
      debugPrint('Apple sign-in error: $e');
      return const AccountResult(AccountResultKind.failed,
          message: 'Sign in with Apple failed.');
    }
  }

  /// Desktop: hand the OAuth round trip to the system browser and poll the
  /// server for the token it mints.
  Future<AccountResult> _signInWithBrowser() async {
    final ticketRes = await _postAsDevice('/api/account/ticket', {});
    if (ticketRes == null) {
      return const AccountResult(AccountResultKind.notConfigured,
          message: 'Browser sign-in is not available on this server yet.');
    }
    final ticket = ticketRes['ticket'] as String?;
    final url = ticketRes['url'] as String?;
    if (ticket == null || url == null) {
      return const AccountResult(AccountResultKind.failed,
          message: 'Could not start sign-in.');
    }
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      return const AccountResult(AccountResultKind.failed,
          message: 'Could not open your browser.');
    }

    // The user is off in a browser; poll until the callback lands. The ticket
    // itself expires server-side after 15 minutes.
    _browserSignInCancelled = false;
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_browserSignInCancelled) {
        return const AccountResult(AccountResultKind.cancelled);
      }
      final poll = await _postAsDevice('/api/account/poll', {'ticket': ticket});
      final status = poll?['status'] as String?;
      if (status == 'ready') {
        final token = poll!['token'] as String?;
        final accountId = poll['accountUserId'] as String?;
        if (token == null || accountId == null) {
          return const AccountResult(AccountResultKind.failed,
              message: 'Sign-in did not complete.');
        }
        await _adoptAccount(
          accountUserId: accountId,
          token: token,
          provider: poll['provider'] as String?,
          email: poll['email'] as String?,
          deviceCount: (poll['deviceCount'] as num?)?.toInt() ?? 1,
        );
        return const AccountResult(AccountResultKind.success);
      }
      if (status == 'error') {
        return AccountResult(AccountResultKind.failed,
            message: poll?['error'] as String? ?? 'Sign-in failed.');
      }
      if (status == 'expired' || status == 'consumed') {
        return const AccountResult(AccountResultKind.cancelled);
      }
    }
    return const AccountResult(AccountResultKind.cancelled);
  }

  Future<AccountResult> _link(String provider, String idToken) async {
    final data = await _postAsDevice('/api/account/link', {
      'provider': provider,
      'idToken': idToken,
    });
    if (data == null) {
      return const AccountResult(AccountResultKind.failed,
          message: 'Could not reach the server. Check your connection.');
    }
    final token = data['token'] as String?;
    final accountId = data['accountUserId'] as String?;
    if (token == null || accountId == null) {
      return const AccountResult(AccountResultKind.failed,
          message: 'Sign-in was rejected.');
    }
    await _adoptAccount(
      accountUserId: accountId,
      token: token,
      provider: data['provider'] as String? ?? provider,
      email: data['email'] as String?,
      deviceCount: (data['deviceCount'] as num?)?.toInt() ?? 1,
    );
    return AccountResult(
      AccountResultKind.success,
      addedMinutes: (data['addedMinutes'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> _adoptAccount({
    required String accountUserId,
    required String token,
    String? provider,
    String? email,
    int deviceCount = 1,
  }) async {
    await UserService.instance.applyAccount(
      accountUserId: accountUserId,
      token: token,
      provider: provider,
      email: email,
    );
    _setState(AccountState(
      linked: true,
      email: email,
      provider: provider,
      deviceCount: deviceCount,
    ));
    await _afterIdentityChange();
  }

  // ── Sign out ────────────────────────────────────────────────────────

  /// Detaches this device. The account keeps the minutes this device folded in
  /// (that is where they live now) and keeps the shared history; the device
  /// falls back to its own free-tier row. Signing back in restores everything,
  /// and the server's contribution ledger makes the round trip non-duplicating.
  Future<void> signOut() async {
    final user = UserService.instance;
    if (user.isAccountLinked) {
      // Best effort — a failure here just leaves a stale server-side token,
      // and the local clear below is what the user actually asked for.
      await _postAsDevice('/api/account/signout', {});
    }
    try {
      if (!usesBrowserFlow && _googleInitialized) {
        await GoogleSignIn.instance.signOut();
      }
    } catch (e) {
      debugPrint('Google sign-out error: $e');
    }
    await user.clearAccount();
    _setState(AccountState.signedOut);
    await _afterIdentityChange();
  }

  // ── Plumbing ────────────────────────────────────────────────────────

  /// Point RevenueCat at whichever identity now owns purchases, and pull the
  /// newly-visible cloud history down. Both are best-effort: a failure leaves
  /// the app usable and self-corrects on the next launch or history open.
  Future<void> _afterIdentityChange() async {
    final id = UserService.instance.userId;
    if (id != null) {
      await PurchaseService.instance.switchUser(id);
    }
    unawaited(SyncService.instance.syncFromServer());
  }

  /// POSTs to an account endpoint authenticated as the device, retrying once
  /// through a device re-registration if the token turns out to be stale.
  /// Returns null on any non-200 (the callers all have a sensible fallback).
  Future<Map<String, dynamic>?> _postAsDevice(
    String path,
    Map<String, dynamic> body, {
    bool allowRetry = true,
  }) async {
    final user = UserService.instance;
    await user.ensureDeviceAuthenticated();
    final deviceId = user.deviceUserId;
    if (deviceId == null) return null;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl$path'),
            headers: user.deviceAuthHeaders,
            body: json.encode({'userId': deviceId, ...body}),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401 && allowRetry) {
        await user.refreshToken();
        return _postAsDevice(path, body, allowRetry: false);
      }
      if (response.statusCode != 200) {
        debugPrint('$path failed: ${response.statusCode} ${response.body}');
        return null;
      }
      return json.decode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('$path error: $e');
      return null;
    }
  }
}
