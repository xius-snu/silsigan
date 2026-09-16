import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/support_message.dart';
import '../../services/push_service.dart';
import '../../services/support_service.dart';
import '../../services/user_service.dart';
import '../../utils/constants.dart';
import 'support_inbox_screen.dart';

/// Entry point for "Contact Support".
///
/// Team members (`users.service_admin`) land in the inbox — or straight in a
/// customer's thread when [threadUserId] names one, e.g. from a notification
/// tap. Everyone else gets their own thread. When the role isn't cached yet
/// the chat screen resolves it on first load and swaps itself for the inbox.
Future<void> openSupport(BuildContext context, {String? threadUserId}) {
  final nav = Navigator.of(context, rootNavigator: true);
  final isAdmin = SupportService.instance.isAdminCached == true;
  final ownId = UserService.instance.userId;
  if (isAdmin && threadUserId != null && threadUserId != ownId) {
    return nav.push(MaterialPageRoute(
      builder: (_) => SupportChatScreen(customerId: threadUserId),
    ));
  }
  if (isAdmin) {
    return nav.push(MaterialPageRoute(
      builder: (_) => const SupportInboxScreen(),
    ));
  }
  return nav.push(MaterialPageRoute(
    builder: (_) => const SupportChatScreen(),
  ));
}

/// 1:1 thread. Without [customerId] it is the caller's own conversation with
/// the team; with one (team members only) it is that customer's thread, and
/// the team's replies render as "mine".
class SupportChatScreen extends StatefulWidget {
  final String? customerId;

  const SupportChatScreen({super.key, this.customerId});

  /// Thread currently on screen, so an in-app notice isn't shown for a
  /// message the user is already looking at.
  static String? _visibleThread;
  static bool isShowingThread(String? threadUserId) =>
      threadUserId != null && _visibleThread == threadUserId;

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen>
    with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 3);

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _messages = <SupportMessage>[];
  int _lastServerId = 0;
  bool _loading = true;
  bool _loadFailed = false;
  bool _canSend = false;
  SupportCustomer? _customer;
  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _resolvedRole = false;
  StreamSubscription<SupportPushEvent>? _pushSub;
  final _rng = Random();

  bool get _isTeamView => widget.customerId != null;
  String? get _threadId => widget.customerId ?? UserService.instance.userId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SupportChatScreen._visibleThread = _threadId;
    _controller.addListener(() {
      final can = _controller.text.trim().isNotEmpty;
      if (can != _canSend) setState(() => _canSend = can);
    });
    // A push for this thread means new content — fetch now, don't wait for
    // the next poll tick.
    _pushSub = PushService.instance.onForegroundMessage.listen((event) {
      if (event.threadUserId == _threadId) _poll();
    });
    _initialLoad();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (SupportChatScreen._visibleThread == _threadId) {
      SupportChatScreen._visibleThread = null;
    }
    _pollTimer?.cancel();
    _pushSub?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      _poll();
    } else if (state == AppLifecycleState.paused) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(_pollInterval, (_) => _poll());
  }

  Future<void> _initialLoad() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final page = await SupportService.instance.fetchThread(
        customerId: widget.customerId,
      );
      if (!mounted) return;
      if (page == null) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        return;
      }
      // Role resolution: a team member who opened "Contact Support" without
      // a cached role belongs in the inbox, not in an empty thread of their
      // own.
      if (!_isTeamView && page.isAdmin && !_resolvedRole) {
        _resolvedRole = true;
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => const SupportInboxScreen(),
        ));
        return;
      }
      _resolvedRole = true;
      _merge(page.messages);
      setState(() {
        _customer = page.customer ?? _customer;
        _loading = false;
      });
      _startPolling();
      _refreshUnreadBadge();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _poll() async {
    if (_pollInFlight || !mounted) return;
    _pollInFlight = true;
    try {
      final page = await SupportService.instance.fetchThread(
        customerId: widget.customerId,
        afterId: _lastServerId,
      );
      if (!mounted || page == null) return;
      final before = _messages.length;
      _merge(page.messages);
      if (page.customer != null) _customer = page.customer;
      if (_messages.length != before || page.customer != null) {
        setState(() {});
      }
      if (page.messages.any((m) => m.fromAdmin != _isTeamView)) {
        _refreshUnreadBadge();
      }
    } catch (_) {
      // Transient — the next tick retries.
    } finally {
      _pollInFlight = false;
    }
  }

  /// Reading marks the thread read server-side; mirror that in the badge.
  void _refreshUnreadBadge() {
    unawaited(SupportService.instance.refreshStatus());
  }

  /// Fold server rows into the local list: replace a pending copy of our own
  /// message by clientId, skip ids we already hold, keep ascending order.
  void _merge(List<SupportMessage> incoming) {
    for (final m in incoming) {
      if (m.id != null && m.id! > _lastServerId) _lastServerId = m.id!;
      final pendingIdx = m.clientId == null
          ? -1
          : _messages.indexWhere(
              (x) => x.clientId != null && x.clientId == m.clientId);
      if (pendingIdx >= 0) {
        _messages[pendingIdx] = m;
        continue;
      }
      if (m.id != null && _messages.any((x) => x.id == m.id)) continue;
      _messages.add(m);
    }
    _messages.sort((a, b) {
      // Pending messages (no id) sort after everything the server has.
      if (a.id == null && b.id == null) {
        return a.createdAt.compareTo(b.createdAt);
      }
      if (a.id == null) return 1;
      if (b.id == null) return -1;
      return a.id!.compareTo(b.id!);
    });
  }

  String _newClientId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = _rng.nextInt(1 << 30).toRadixString(36);
    return '$ts-$salt';
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    final local = SupportMessage(
      id: null,
      text: text,
      fromAdmin: _isTeamView,
      createdAt: DateTime.now(),
      clientId: _newClientId(),
      state: SupportSendState.sending,
    );
    setState(() => _messages.add(local));
    HapticFeedback.lightImpact();
    await _deliver(local);
  }

  Future<void> _deliver(SupportMessage local) async {
    final wasFirst = _messages.where((m) => m.id != null).isEmpty;
    try {
      final sent = await SupportService.instance.send(
        text: local.text,
        clientId: local.clientId!,
        customerId: widget.customerId,
      );
      if (!mounted) return;
      final idx = _messages.indexWhere((m) => m.clientId == local.clientId);
      if (sent == null) {
        if (idx >= 0) {
          setState(() =>
              _messages[idx] = local.copyWith(state: SupportSendState.failed));
        }
        return;
      }
      if (idx >= 0) {
        setState(() => _messages[idx] = sent);
      }
      if (sent.id != null && sent.id! > _lastServerId) {
        _lastServerId = sent.id!;
      }
      // The first message is the moment a notification becomes obviously
      // useful — ask now rather than at launch.
      if (wasFirst && !_isTeamView) _maybeAskForNotifications();
    } catch (e) {
      if (!mounted) return;
      final idx = _messages.indexWhere((m) => m.clientId == local.clientId);
      if (idx >= 0) {
        setState(() =>
            _messages[idx] = local.copyWith(state: SupportSendState.failed));
      }
      if (e is SupportException && e.statusCode == 429) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    }
  }

  Future<void> _maybeAskForNotifications() async {
    final push = PushService.instance;
    if (!push.isAvailable) return;
    if (await push.isPermissionGranted()) return;
    await push.requestPermission();
  }

  Future<void> _retry(SupportMessage failed) async {
    final idx = _messages.indexWhere((m) => m.clientId == failed.clientId);
    if (idx < 0) return;
    setState(() =>
        _messages[idx] = failed.copyWith(state: SupportSendState.sending));
    await _deliver(_messages[idx]);
  }

  void _copyCustomerId() {
    final id = _customer?.id ?? widget.customerId;
    if (id == null) return;
    Clipboard.setData(ClipboardData(text: id));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Customer ID copied'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _copyMyId() {
    final id = UserService.instance.friendCode;
    if (id == null || id.isEmpty) return;
    Clipboard.setData(ClipboardData(text: id));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ID copied'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  bool _isMine(SupportMessage m) => m.fromAdmin == _isTeamView;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
            _buildComposer(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final String title;
    final String? subtitle;
    if (_isTeamView) {
      final id = widget.customerId!;
      title = _customer?.label ?? (id.length > 8 ? id.substring(0, 8) : id);
      final c = _customer;
      subtitle = c == null
          ? null
          : [
              if (c.isPrivate) 'private',
              '${_fmtMinutes(c.remainingSeconds ~/ 60)} left',
              '${_fmtMinutes(c.usedSeconds ~/ 60)} used',
              if (c.isAccount) 'account',
            ].join(' · ');
    } else {
      final id = UserService.instance.friendCode;
      title = id == null || id.isEmpty ? 'Support' : 'Support (My ID: $id)';
      subtitle = 'Silsigan team';
    }
    return Padding(
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
            child: GestureDetector(
              onTap: _isTeamView ? _copyCustomerId : _copyMyId,
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppConstants.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
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
    if (_loadFailed && _messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Couldn't load messages",
              style: TextStyle(fontSize: 14, color: AppConstants.textMuted),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _initialLoad,
              child: Text(
                'Retry',
                style: TextStyle(color: AppConstants.textPrimary),
              ),
            ),
          ],
        ),
      );
    }
    if (_messages.isEmpty) {
      return _buildEmptyState();
    }
    final showTicketNotice = !_isTeamView &&
        _messages.any((m) => m.state != SupportSendState.failed);
    return SelectionArea(
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        itemCount: _messages.length + (showTicketNotice ? 1 : 0),
        itemBuilder: (context, i) {
          if (showTicketNotice && i == _messages.length) {
            return _buildTicketNotice();
          }
          final index = _messages.length - 1 - i;
          final m = _messages[index];
          final prev = index > 0 ? _messages[index - 1] : null;
          final showStamp = prev == null ||
              m.createdAt.difference(prev.createdAt).inMinutes.abs() >= 15;
          final next =
              index + 1 < _messages.length ? _messages[index + 1] : null;
          final continuesBelow = next != null &&
              _isMine(next) == _isMine(m) &&
              next.createdAt.difference(m.createdAt).inMinutes < 15;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showStamp) _buildStamp(m.createdAt),
              _buildBubble(m, tight: continuesBelow),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTicketNotice() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Text(
        'Support ticket created. We\'ll notify you when we reply — '
        'you can leave this screen.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: AppConstants.textFaint,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final text = _isTeamView
        ? 'No messages yet.'
        : 'Hi — tell us what\'s going on.\n\n'
            'A person on the Silsigan team will reply here.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: AppConstants.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildStamp(DateTime at) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Text(
        _formatStamp(context, at),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: AppConstants.textFaint),
      ),
    );
  }

  Widget _buildBubble(SupportMessage m, {required bool tight}) {
    final mine = _isMine(m);
    final failed = m.state == SupportSendState.failed;
    final sending = m.state == SupportSendState.sending;
    final bg = mine ? AppConstants.micButtonColor : AppConstants.panelColor;
    final fg = mine ? AppConstants.micIconColor : AppConstants.textPrimary;
    const r = Radius.circular(18);
    const tail = Radius.circular(5);
    final radius = mine
        ? const BorderRadius.only(
            topLeft: r, topRight: r, bottomLeft: r, bottomRight: tail)
        : const BorderRadius.only(
            topLeft: r, topRight: r, bottomLeft: tail, bottomRight: r);
    final maxWidth = MediaQuery.of(context).size.width * 0.78;

    return Padding(
      padding: EdgeInsets.only(bottom: tight ? 3 : 10),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: failed ? () => _retry(m) : null,
            child: Opacity(
              opacity: sending ? 0.6 : 1,
              child: Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: bg, borderRadius: radius),
                child: Text(
                  m.text,
                  style: TextStyle(fontSize: 15, height: 1.35, color: fg),
                ),
              ),
            ),
          ),
          if (failed)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: Text(
                'Not delivered · Tap to retry',
                style: TextStyle(fontSize: 11, color: Colors.red.shade400),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    final sendColor =
        _canSend ? AppConstants.micButtonColor : AppConstants.saveButtonColor;
    final sendIcon =
        _canSend ? AppConstants.micIconColor : AppConstants.textMuted;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppConstants.panelColor,
                borderRadius: BorderRadius.circular(22),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                minLines: 1,
                maxLines: 5,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: TextStyle(
                  fontSize: 15,
                  color: AppConstants.textPrimary,
                ),
                cursorColor: AppConstants.textPrimary,
                decoration: InputDecoration(
                  isCollapsed: true,
                  counterText: '',
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: InputBorder.none,
                  hintText: _isTeamView ? 'Reply…' : 'Message…',
                  hintStyle: TextStyle(
                    fontSize: 15,
                    color: AppConstants.textMuted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _canSend ? _send : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 40,
              height: 40,
              margin: const EdgeInsets.only(bottom: 2),
              decoration: BoxDecoration(
                color: sendColor,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.arrow_upward, size: 20, color: sendIcon),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtMinutes(int minutes) {
  if (minutes < 60) return '${minutes}m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

const _monthAbbr = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "14:32" today, "Yesterday 14:32", "Sep 12, 14:32" this year, else the
/// full date. Time honours the device's 12/24-hour preference.
String _formatStamp(BuildContext context, DateTime at) {
  final now = DateTime.now();
  final time = TimeOfDay.fromDateTime(at).format(context);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return time;
  if (diff == 1) return 'Yesterday $time';
  final md = '${_monthAbbr[at.month - 1]} ${at.day}';
  if (at.year == now.year) return '$md, $time';
  return '$md ${at.year}, $time';
}

/// Shared with the inbox for its "last activity" column.
String formatSupportStamp(BuildContext context, DateTime at) =>
    _formatStamp(context, at);
