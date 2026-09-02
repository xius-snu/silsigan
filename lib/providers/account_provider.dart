import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/account_service.dart';

/// Mirrors [AccountService.state] into the widget tree.
///
/// AccountService owns the truth (it persists to SharedPreferences and talks
/// to the server); this provider exists so the header icon and the account
/// sheet rebuild when sign-in state changes. Whoever mutates the account must
/// push the new state here — see `_syncAccountState` in MainScreen.
final accountProvider = StateProvider<AccountState>(
  (ref) => AccountService.instance.state,
);
