import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import '../../providers/account_provider.dart';
import '../../services/account_service.dart';
import '../../utils/constants.dart';

/// Opens the optional account-sync sheet.
///
/// Signing in or out here repoints usage, purchases and cloud history at a
/// different server row, so callers should refresh those once it closes —
/// which can happen by dismissal as well as by a button, hence no return value
/// to check.
Future<void> showAccountSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const _AccountSheet(),
  );
}

class _AccountSheet extends ConsumerStatefulWidget {
  const _AccountSheet();

  @override
  ConsumerState<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<_AccountSheet> {
  bool _busy = false;
  String? _error;

  /// Set while the desktop flow is parked in the system browser — the sheet
  /// can be waiting for minutes there, so it needs its own explanation.
  bool _waitingForBrowser = false;

  /// Purchased minutes this device just folded in, shown as confirmation.
  int _addedMinutes = 0;

  Future<void> _run(Future<AccountResult> Function() action,
      {bool browser = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _waitingForBrowser = browser;
    });
    final result = await action();
    if (!mounted) return;
    // Success re-renders this sheet into its signed-in state rather than
    // closing it — that view (email, device count, time added) is the
    // confirmation, and a sheet that vanishes leaves nothing to read.
    if (result.isSuccess) {
      ref.read(accountProvider.notifier).state = AccountService.instance.state;
    }
    setState(() {
      _busy = false;
      _waitingForBrowser = false;
      _addedMinutes = result.addedMinutes;
      _error =
          result.kind == AccountResultKind.cancelled ? null : result.message;
    });
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out'),
        content: Text(
          'This device stops sharing recordings and goes back to its own '
          'free ${AppConstants.freeBaseMinutes} minutes. The time you added '
          'stays in your account — sign in again to use it.',
          style: TextStyle(color: AppConstants.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await AccountService.instance.signOut();
    if (!mounted) return;
    ref.read(accountProvider.notifier).state = AccountService.instance.state;
    setState(() {
      _busy = false;
      _addedMinutes = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final media = MediaQuery.of(context);
    // Modal sheets sit outside the scaffold SafeArea; Android's nav inset
    // would otherwise cover the last row (same fix as the purchase sheet).
    final navInset =
        !kIsWeb && Platform.isAndroid ? media.viewPadding.bottom : 0.0;

    // A native sign-in in flight owns the screen, so block dismissal until it
    // returns. The desktop browser wait is different — it can sit for minutes
    // on a tab the user already abandoned, so that one stays escapable.
    return PopScope(
      canPop: !_busy || _waitingForBrowser,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: media.size.height - media.viewPadding.top - 12,
        ),
        decoration: BoxDecoration(
          color: AppConstants.sheetColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom + navInset),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppConstants.textFaint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (account.linked)
                ..._buildSignedIn(account)
              else
                ..._buildSignedOut(),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(fontSize: 13, color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Signed out ──────────────────────────────────────────────────────

  List<Widget> _buildSignedOut() {
    return [
      Icon(Icons.cloud_sync_outlined, size: 34, color: AppConstants.textMuted),
      const SizedBox(height: 12),
      Text(
        'Sync your account',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: AppConstants.textPrimary,
        ),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 4),
      Text(
        'Optional. Use one balance and one history across your devices.',
        style: TextStyle(fontSize: 14, color: AppConstants.textMuted),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 20),
      _bullet(
        Icons.schedule,
        'Time is combined',
        'The time you bought on each device adds up. The free '
            '${AppConstants.freeBaseMinutes} minutes counts once, not once per '
            'device.',
      ),
      _bullet(
        Icons.history,
        'Recordings are shared',
        'Saved transcripts appear on every signed-in device. Audio stays on '
            'the device that recorded it.',
      ),
      const SizedBox(height: 20),
      if (_busy) ...[
        Center(
          child: Column(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppConstants.textSecondary),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _waitingForBrowser
                    ? 'Finish signing in from your browser, then come back.'
                    : 'Signing in…',
                style: TextStyle(fontSize: 13, color: AppConstants.textMuted),
                textAlign: TextAlign.center,
              ),
              if (_waitingForBrowser)
                TextButton(
                  onPressed: AccountService.instance.cancelBrowserSignIn,
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                        fontSize: 13, color: AppConstants.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ] else ...[
        if (AccountService.googleConfigured || AccountService.usesBrowserFlow)
          _googleButton(),
        if (AccountService.appleAvailable) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: SignInWithAppleButton(
              onPressed: () => _run(AccountService.instance.signInWithApple),
              style: AppConstants.isDark
                  ? SignInWithAppleButtonStyle.white
                  : SignInWithAppleButtonStyle.black,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ],
      ],
      const SizedBox(height: 16),
      Text(
        'Signing in moves the time you bought on this device into your '
        'account, so it can be used from any of your devices.',
        style: TextStyle(fontSize: 11, color: AppConstants.textFaint),
        textAlign: TextAlign.center,
      ),
    ];
  }

  Widget _googleButton() {
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: () => _run(
          AccountService.instance.signInWithGoogle,
          browser: AccountService.usesBrowserFlow,
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: AppConstants.cardColor,
          side: BorderSide(color: AppConstants.cardBorderColor),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF4285F4),
              ),
              child: const Text(
                'G',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Continue with Google',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppConstants.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bullet(IconData icon, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppConstants.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppConstants.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: AppConstants.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatMinutes(int minutes) {
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours hr' : '$hours hr $rest min';
  }

  // ── Signed in ───────────────────────────────────────────────────────

  List<Widget> _buildSignedIn(AccountState account) {
    final providerLabel = account.provider == 'apple'
        ? 'Apple'
        : account.provider == 'google'
            ? 'Google'
            : null;
    return [
      Icon(Icons.cloud_done_outlined, size: 34, color: AppConstants.textMuted),
      const SizedBox(height: 12),
      Text(
        'Account synced',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: AppConstants.textPrimary,
        ),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 6),
      Text(
        account.email ??
            (providerLabel != null
                ? 'Signed in with $providerLabel'
                : 'Signed in'),
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: AppConstants.textSecondary,
        ),
        textAlign: TextAlign.center,
      ),
      if (account.email != null && providerLabel != null) ...[
        const SizedBox(height: 2),
        Text(
          'via $providerLabel',
          style: TextStyle(fontSize: 12, color: AppConstants.textMuted),
          textAlign: TextAlign.center,
        ),
      ],
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppConstants.cardHighlightColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppConstants.cardBorderColor),
        ),
        child: Row(
          children: [
            Icon(Icons.devices, size: 18, color: AppConstants.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                account.deviceCount <= 1
                    ? 'This is the only device signed in. Sign in on another '
                        'device to combine its time.'
                    : '${account.deviceCount} devices share this balance and '
                        'history.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  color: AppConstants.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
      if (_addedMinutes > 0) ...[
        const SizedBox(height: 12),
        Text(
          '${_formatMinutes(_addedMinutes)} moved from this device into your '
          'account.',
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF2E7D32)),
          textAlign: TextAlign.center,
        ),
      ],
      const SizedBox(height: 20),
      if (_busy)
        Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppConstants.textSecondary),
            ),
          ),
        )
      else
        Center(
          child: TextButton(
            onPressed: _signOut,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Sign out on this device'),
          ),
        ),
    ];
  }
}
