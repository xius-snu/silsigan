import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:http/http.dart' as http;
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

      // Tell our server to credit the minutes.
      final credited = await _creditMinutesOnServer(
        minutes: minutes,
        productId: package.storeProduct.identifier,
        transactionId: result.nonSubscriptionTransactions.isNotEmpty
            ? result.nonSubscriptionTransactions.last.transactionIdentifier
            : null,
      );
      return credited ? minutes : null;
    } on PurchasesErrorCode catch (e) {
      if (e == PurchasesErrorCode.purchaseCancelledError) {
        debugPrint('Purchase cancelled');
        return null;
      }
      debugPrint('Purchase error: $e');
      return null;
    } catch (e) {
      debugPrint('Purchase error: $e');
      return null;
    }
  }

  /// Notify our backend to add minutes after a verified purchase.
  Future<bool> _creditMinutesOnServer({
    required int minutes,
    required String productId,
    String? transactionId,
  }) async {
    final userId = UserService.instance.userId;
    if (userId == null) return false;
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
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        return true;
      }
      debugPrint('Credit purchase error: ${response.statusCode} ${response.body}');
      return false;
    } catch (e) {
      debugPrint('Credit purchase network error: $e');
      return false;
    }
  }
}
