import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../providers/target_language_provider.dart';
import '../../services/user_service.dart';
import '../../utils/constants.dart';

class FriendDialog extends StatefulWidget {
  const FriendDialog({super.key});

  @override
  State<FriendDialog> createState() => _FriendDialogState();
}

class _FriendDialogState extends State<FriendDialog> {
  final _searchController = TextEditingController();
  final _userService = UserService.instance;

  List<dynamic> _friends = [];
  List<dynamic> _incoming = [];
  List<dynamic> _outgoing = [];
  bool _loading = true;
  String? _searchError;
  Map<String, dynamic>? _searchResult;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    setState(() => _loading = true);
    final data = await _userService.listFriends();
    if (mounted) {
      setState(() {
        _friends = data['friends'] as List<dynamic>? ?? [];
        _incoming = data['incoming'] as List<dynamic>? ?? [];
        _outgoing = data['outgoing'] as List<dynamic>? ?? [];
        _loading = false;
      });
    }
  }

  Future<void> _searchFriend() async {
    final code = _searchController.text.trim().toUpperCase();
    if (code.isEmpty || code.length != 8) {
      setState(() => _searchError = 'Enter 8-character code');
      return;
    }
    if (code == _userService.friendCode) {
      setState(() => _searchError = "That's your own code");
      return;
    }

    setState(() {
      _searching = true;
      _searchError = null;
      _searchResult = null;
    });

    final result = await _userService.lookupByFriendCode(code);
    if (mounted) {
      setState(() {
        _searching = false;
        if (result != null) {
          _searchResult = result;
        } else {
          _searchError = 'User not found';
        }
      });
    }
  }

  Future<void> _addFriend(String friendId) async {
    final result = await _userService.sendFriendRequest(friendId);
    if (mounted) {
      if (result != null && result['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result['status'] == 'accepted'
                  ? 'Friend added!'
                  : 'Request sent!',
            ),
          ),
        );
        setState(() {
          _searchResult = null;
          _searchController.clear();
        });
        _loadFriends();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result?['error'] ?? 'Failed to send request'),
          ),
        );
      }
    }
  }

  Future<void> _acceptRequest(String requesterId) async {
    final success = await _userService.acceptFriendRequest(requesterId);
    if (mounted && success) _loadFriends();
  }

  Future<void> _declineRequest(String requesterId) async {
    final success = await _userService.declineFriendRequest(requesterId);
    if (mounted && success) _loadFriends();
  }

  Future<void> _cancelRequest(String friendId) async {
    final success = await _userService.cancelFriendRequest(friendId);
    if (mounted && success) _loadFriends();
  }

  Future<void> _removeFriend(String friendId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Friend'),
        content: const Text('Remove this friend?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final success = await _userService.removeFriend(friendId);
      if (mounted && success) _loadFriends();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppConstants.panelColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
          maxWidth: 340,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Friends',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(
                      Icons.close,
                      color: AppConstants.textSecondary,
                      size: 22,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Your Code
              const Text(
                'YOUR CODE',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppConstants.textSecondary,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppConstants.bgColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _userService.friendCode ?? '...',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppConstants.textPrimary,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        if (_userService.friendCode != null) {
                          Clipboard.setData(
                            ClipboardData(text: _userService.friendCode!),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Code copied!')),
                          );
                        }
                      },
                      child: const Icon(
                        Icons.copy,
                        size: 18,
                        color: AppConstants.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Add Friend
              const Text(
                'ADD FRIEND',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppConstants.textSecondary,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 8,
                      decoration: InputDecoration(
                        hintText: 'Enter friend code',
                        hintStyle: TextStyle(color: Colors.grey.shade400),
                        counterText: '',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        filled: true,
                        fillColor: AppConstants.bgColor,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      style: const TextStyle(
                        fontSize: 15,
                        letterSpacing: 1.5,
                        color: AppConstants.textPrimary,
                      ),
                      onSubmitted: (_) => _searchFriend(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _searching ? null : _searchFriend,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppConstants.textPrimary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _searching
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.search,
                              color: Colors.white,
                              size: 18,
                            ),
                    ),
                  ),
                ],
              ),
              if (_searchError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _searchError!,
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                  ),
                ),
              if (_searchResult != null)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppConstants.bgColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.person_outline,
                        size: 18,
                        color: AppConstants.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _searchResult!['friend_code'] ?? '',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () =>
                            _addFriend(_searchResult!['user_id'] as String),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppConstants.textPrimary,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'Add',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),

              // Scrollable content: requests + friends
              Flexible(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_incoming.isNotEmpty) ...[
                              _sectionHeader('REQUESTS', _incoming.length),
                              ..._incoming
                                  .map((r) => _requestTile(r, incoming: true)),
                              const SizedBox(height: 12),
                            ],
                            if (_outgoing.isNotEmpty) ...[
                              _sectionHeader('PENDING', _outgoing.length),
                              ..._outgoing.map(
                                  (r) => _requestTile(r, incoming: false)),
                              const SizedBox(height: 12),
                            ],
                            _sectionHeader('FRIENDS', _friends.length),
                            if (_friends.isEmpty)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: Text(
                                    'No friends yet',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade400,
                                    ),
                                  ),
                                ),
                              )
                            else
                              ..._friends.map(_friendTile),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '$title ($count)',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppConstants.textSecondary,
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _requestTile(dynamic request, {required bool incoming}) {
    final code = (request as Map<String, dynamic>)['friend_code'] as String? ??
        '????????';
    final id = request['user_id'] as String;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppConstants.bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              code,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppConstants.textPrimary,
              ),
            ),
          ),
          if (incoming) ...[
            GestureDetector(
              onTap: () => _acceptRequest(id),
              child: Container(
                padding: const EdgeInsets.all(4),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.check,
                  size: 18,
                  color: Colors.green.shade700,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => _declineRequest(id),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.close,
                  size: 18,
                  color: Colors.red.shade700,
                ),
              ),
            ),
          ] else
            GestureDetector(
              onTap: () => _cancelRequest(id),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppConstants.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _startSession(String friendId, String friendCode) async {
    final language = await showDialog<TargetLanguage>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select your language'),
        children: TargetLanguage.values
            .map(
              (lang) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, lang),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(lang.displayName, style: const TextStyle(fontSize: 16)),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (language == null) return;

    final result =
        await _userService.sendSessionInvite(friendId, language.code);
    if (!mounted) return;

    if (result != null && result['success'] == true) {
      Navigator.pop(context, {
        'type': 'session_invite',
        'inviteId': result['inviteId'],
        'friendCode': friendCode,
        'friendId': friendId,
        'myLanguage': language.code,
        'status': result['status'],
        if (result['status'] == 'accepted') ...{
          'sessionId': result['sessionId'],
          'partnerLanguage': result['partnerLanguage'],
        },
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(result?['error'] ?? 'Failed to send invite')),
      );
    }
  }

  void _showFriendMenu(
      BuildContext context, String userId, String code, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(
          value: 'session',
          child: Row(
            children: [
              Icon(Icons.call, size: 18, color: AppConstants.textSecondary),
              SizedBox(width: 8),
              Text('Start Session'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.person_remove, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Remove Friend', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'session') _startSession(userId, code);
      if (value == 'remove') _removeFriend(userId);
    });
  }

  Widget _friendTile(dynamic friend) {
    final code = (friend as Map<String, dynamic>)['friend_code'] as String? ??
        '????????';
    final id = friend['user_id'] as String;
    return GestureDetector(
      onTapDown: (details) =>
          _showFriendMenu(context, id, code, details.globalPosition),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppConstants.bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.person,
              size: 18,
              color: AppConstants.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                code,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppConstants.textPrimary,
                ),
              ),
            ),
            Icon(
              Icons.more_vert,
              size: 18,
              color: Colors.grey.shade400,
            ),
          ],
        ),
      ),
    );
  }
}
