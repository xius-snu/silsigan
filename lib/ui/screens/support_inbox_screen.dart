import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/support_message.dart';
import '../../services/push_service.dart';
import '../../services/support_service.dart';
import '../../utils/constants.dart';
import 'support_chat_screen.dart';

/// Team view: every customer thread, newest activity first. Only reachable
/// when the server says this identity has `service_admin` set.
class SupportInboxScreen extends StatefulWidget {
  const SupportInboxScreen({super.key});

  /// True while the inbox is on screen (so a foreground push doesn't also
  /// raise an in-app notice — the list refreshes itself).
  static bool isOpen = false;

  @override
  State<SupportInboxScreen> createState() => _SupportInboxScreenState();
}

class _SupportInboxScreenState extends State<SupportInboxScreen>
    with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 5);

  List<SupportThreadSummary>? _threads;
  bool _loadFailed = false;
  Timer? _pollTimer;
  bool _inFlight = false;
  StreamSubscription<SupportPushEvent>? _pushSub;

  @override
  void initState() {
    super.initState();
    SupportInboxScreen.isOpen = true;
    WidgetsBinding.instance.addObserver(this);
    _pushSub = PushService.instance.onForegroundMessage.listen((_) => _load());
    _load();
    _startPolling();
    // Team members want to hear about new customer messages — ask once here
    // if the OS hasn't been asked yet.
    _ensureNotifications();
  }

  @override
  void dispose() {
    SupportInboxScreen.isOpen = false;
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _pushSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _load();
    } else if (state == AppLifecycleState.paused) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(_pollInterval, (_) => _load());
  }

  Future<void> _ensureNotifications() async {
    final push = PushService.instance;
    if (!push.isAvailable) return;
    if (await push.isPermissionGranted()) {
      await push.syncToken();
      return;
    }
    await push.requestPermission();
  }

  Future<void> _load() async {
    if (_inFlight || !mounted) return;
    _inFlight = true;
    try {
      final threads = await SupportService.instance.fetchThreads();
      if (!mounted) return;
      setState(() {
        if (threads != null) {
          _threads = threads;
          _loadFailed = false;
        } else if (_threads == null) {
          _loadFailed = true;
        }
      });
      unawaited(SupportService.instance.refreshStatus());
    } catch (_) {
      if (!mounted) return;
      if (_threads == null) setState(() => _loadFailed = true);
    } finally {
      _inFlight = false;
    }
  }

  Future<void> _open(SupportThreadSummary t) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SupportChatScreen(customerId: t.userId),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _threads?.where((t) => t.unread > 0).length ?? 0;
    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(Icons.arrow_back_ios_new,
                        size: 20, color: AppConstants.textPrimary),
                    tooltip: 'Back',
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Support inbox',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                        if (_threads != null)
                          Text(
                            waiting == 0
                                ? 'All caught up'
                                : '$waiting waiting for a reply',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppConstants.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final threads = _threads;
    if (threads == null) {
      if (_loadFailed) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Couldn't load conversations",
                style: TextStyle(fontSize: 14, color: AppConstants.textMuted),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _load,
                child: Text('Retry',
                    style: TextStyle(color: AppConstants.textPrimary)),
              ),
            ],
          ),
        );
      }
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppConstants.textMuted,
          ),
        ),
      );
    }
    if (threads.isEmpty) {
      return Center(
        child: Text(
          'No conversations yet.',
          style: TextStyle(fontSize: 14, color: AppConstants.textMuted),
        ),
      );
    }
    return RefreshIndicator(
      color: AppConstants.textPrimary,
      backgroundColor: AppConstants.panelColor,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: threads.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 1,
          indent: 76,
          color: AppConstants.dividerColor,
        ),
        itemBuilder: (context, i) => _buildRow(threads[i]),
      ),
    );
  }

  Widget _buildRow(SupportThreadSummary t) {
    final unread = t.unread > 0;
    final initials = t.label.trim().isEmpty
        ? '?'
        : t.label
            .trim()
            .substring(0, t.label.trim().length >= 2 ? 2 : 1)
            .toUpperCase();
    return InkWell(
      onTap: () => _open(t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppConstants.panelColor,
                shape: BoxShape.circle,
                border: Border.all(color: AppConstants.cardBorderColor),
              ),
              child: Text(
                initials,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppConstants.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                unread ? FontWeight.w600 : FontWeight.w500,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                      ),
                      if (t.lastMessageAt != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            formatSupportStamp(context, t.lastMessageAt!),
                            style: TextStyle(
                              fontSize: 11,
                              color: AppConstants.textFaint,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.lastFromAdmin ? 'You: ${t.preview}' : t.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: unread
                                ? AppConstants.textSecondary
                                : AppConstants.textMuted,
                          ),
                        ),
                      ),
                      if (unread)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 8),
                          decoration: BoxDecoration(
                            color: AppConstants.micButtonColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
