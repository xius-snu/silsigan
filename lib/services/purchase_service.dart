import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import 'user_service.dart';

/// Maps RevenueCat package identifiers to the number of minutes granted.
const _packageMinutes = {
  'hours_1': 60,
  'hours_5': 300,
  'hours_10': 600,
  'hours_30': 1800,
  'hours_50': 3000,
};

class PurchaseService {
  static final PurchaseService instance = PurchaseService._();
  PurchaseService._();

  static const _apiKey = 'appl_CtsSSvxoAlcxysdpTOomFleNOof';
  static const _pendingKey = 'pending_purchases';
  static final Random _rand = Random();

  bool _initialized = false;
  Offerings? _offerings;

  Offerings? get offerings => _offerings;
  bool get isInitialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    try {
      await Purchases.setLogLevel(LogLevel.debug);
      final userId = UserService.instance.userId;
      final config = PurchasesConfiguration(_apiKey);
      if (userId != null) {
        config.appUserID = userId;
      }
      await Purchases.configure(config);
      _initialized = true;
      await refreshOfferings();
      // Retry any purchases that succeeded with Apple but failed to credit
      await _retryPendingPurchases();
    } catch (e) {
      debugPrint('PurchaseService init error: $e');
    }
  }

  Future<void> refreshOfferings() async {
    try {
      _offerings = await Purchases.getOfferings();
    } catch (e) {
      debugPrint('Failed to fetch offerings: $e');
    }
  }

  /// Returns the list of packages from the default offering.
  List<Package> get availablePackages {
    return _offerings?.current?.availablePackages ?? [];
  }

  /// Purchase a package. Returns the number of minutes granted, or null on
  /// failure/cancellation.
  Future<int?> purchase(Package package) async {
    try {
      final result = await Purchases.purchasePackage(package);
      // Find how many minutes this package grants.
      final id = package.identifier;
      final minutes = _packageMinutes[id];
      if (minutes == null) {
        debugPrint('Unknown package id: $id');
        return null;
      }

      final productId = package.storeProduct.identifier;

      // Get transaction ID from the purchase result.
      String? transactionId;
      final txns = result.nonSubscriptionTransactions;
      if (txns.isNotEmpty) {
        transactionId = txns.last.transactionIdentifier;
      }

      // Stable per-purchase idempotency key. Unlike transactionId (which can be
      // null when RevenueCat hasn't surfaced the transaction yet), this is
      // always present and unique, so the server dedups retries correctly and
      // we can remove exactly this pending entry on success.
      final idempotencyKey = _generateIdempotencyKey();

      // Save as pending BEFORE calling the server, so if the app crashes or
      // network fails we can retry on next launch.
      await _savePendingPurchase(
        productId: productId,
        minutes: minutes,
        transactionId: transactionId,
        idempotencyKey: idempotencyKey,
      );

      // Tell our server to credit the minutes (with retries).
      final credited = await _creditMinutesOnServer(
        minutes: minutes,
        productId: productId,
        transactionId: transactionId,
        idempotencyKey: idempotencyKey,
      );

      if (credited) {
        await _removePendingPurchase(idempotencyKey);
      }
      // Return minutes even if server credit failed — the purchase is saved
      // locally and will be retried. The user paid, so show success.
      return minutes;
    } on PlatformException catch (e) {
      final errorCode = PurchasesErrorHelper.getErrorCode(e);
      if (errorCode == PurchasesErrorCode.purchaseCancelledError) {
        debugPrint('Purchase cancelled');
        return null;
      }
      debugPrint('Purchase error: $errorCode — ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Purchase error: $e');
      return null;
    }
  }

  /// Notify our backend to add minutes after a verified purchase.
  /// Retries up to 3 times with backoff.
  Future<bool> _creditMinutesOnServer({
    required int minutes,
    required String productId,
    String? transactionId,
    String? idempotencyKey,
  }) async {
    final userId = UserService.instance.userId;
    if (userId == null) return false;

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await UserService.instance.ensureAuthenticated();
        final response = await http
            .post(
              Uri.parse('${AppConstants.serverBaseUrl}/api/user/purchase'),
              headers: {
                'Content-Type': 'application/json',
                if (UserService.instance.authToken != null)
                  'Authorization': 'Bearer ${UserService.instance.authToken}',
              },
              body: json.encode({
                'userId': userId,
                'minutes': minutes,
                'productId': productId,
                if (transactionId != null) 'transactionId': transactionId,
                if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          return true;
        }
        debugPrint('Credit purchase error (attempt $attempt): '
            '${response.statusCode} ${response.body}');
      } catch (e) {
        debugPrint('Credit purchase network error (attempt $attempt): $e');
      }
      // Wait before retrying (1s, 3s)
      if (attempt < 2) {
        await Future.delayed(Duration(seconds: attempt == 0 ? 1 : 3));
      }
    }
    return false;
  }

  // ==================
  // PENDING PURCHASE PERSISTENCE
  // ==================

  /// Stable, unique per-purchase idempotency key — generated once and reused
  /// across retries via the persisted pending entry.
  String _generateIdempotencyKey() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final a = _rand.nextInt(1 << 31);
    final b = _rand.nextInt(1 << 31);
    return 'idem_${ts}_${a}_$b';
  }

  Future<void> _savePendingPurchase({
    required String productId,
    required int minutes,
    String? transactionId,
    required String idempotencyKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingKey) ?? [];
    final entry = json.encode({
      'productId': productId,
      'minutes': minutes,
      'transactionId': transactionId,
      'idempotencyKey': idempotencyKey,
      'key': idempotencyKey,
    });
    pending.add(entry);
    await prefs.setStringList(_pendingKey, pending);
  }

  Future<void> _removePendingPurchase(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingKey) ?? [];
    pending.removeWhere((e) {
      try {
        final data = json.decode(e) as Map<String, dynamic>;
        return data['key'] == key;
      } catch (_) {
        return false;
      }
    });
    await prefs.setStringList(_pendingKey, pending);
  }

  /// Retry any purchases that Apple charged but our server didn't credit.
  Future<void> _retryPendingPurchases() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingKey) ?? [];
    if (pending.isEmpty) return;

    debugPrint('Retrying ${pending.length} pending purchase(s)...');
    for (final entry in List<String>.from(pending)) {
      try {
        final data = json.decode(entry) as Map<String, dynamic>;
        final credited = await _creditMinutesOnServer(
          minutes: data['minutes'] as int,
          productId: data['productId'] as String,
          transactionId: data['transactionId'] as String?,
          idempotencyKey: data['idempotencyKey'] as String?,
        );
        if (credited) {
          await _removePendingPurchase(data['key'] as String);
        }
      } catch (e) {
        debugPrint('Retry pending purchase error: $e');
      }
    }
  }
}
