/// Delivery state of a message as seen by the device that authored it.
enum SupportSendState { sending, sent, failed }

/// One message in a support thread. [isMine] is resolved by the caller from
/// its point of view: a customer's own messages, or — for a team member
/// reading a customer's thread — the team's replies.
class SupportMessage {
  final int? id;
  final String text;
  final bool fromAdmin;
  final DateTime createdAt;
  final String? clientId;
  final SupportSendState state;

  const SupportMessage({
    required this.id,
    required this.text,
    required this.fromAdmin,
    required this.createdAt,
    this.clientId,
    this.state = SupportSendState.sent,
  });

  factory SupportMessage.fromJson(Map<String, dynamic> json) {
    return SupportMessage(
      id: (json['id'] as num?)?.toInt(),
      text: json['text'] as String? ?? '',
      fromAdmin: json['fromAdmin'] == true,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
      clientId: json['clientId'] as String?,
    );
  }

  SupportMessage copyWith({
    int? id,
    SupportSendState? state,
    DateTime? createdAt,
  }) {
    return SupportMessage(
      id: id ?? this.id,
      text: text,
      fromAdmin: fromAdmin,
      createdAt: createdAt ?? this.createdAt,
      clientId: clientId,
      state: state ?? this.state,
    );
  }
}

/// A customer as the team sees them in the inbox / chat header.
class SupportCustomer {
  final String id;
  final String label;
  final bool isAccount;
  final int limitMinutes;
  final int usedSeconds;
  final bool isPrivate;

  const SupportCustomer({
    required this.id,
    required this.label,
    required this.isAccount,
    required this.limitMinutes,
    required this.usedSeconds,
    required this.isPrivate,
  });

  factory SupportCustomer.fromJson(Map<String, dynamic> json) {
    return SupportCustomer(
      id: json['id'] as String,
      label: json['label'] as String? ?? (json['id'] as String),
      isAccount: json['isAccount'] == true,
      limitMinutes: (json['limitMinutes'] as num?)?.toInt() ?? 0,
      usedSeconds: (json['usedSeconds'] as num?)?.toInt() ?? 0,
      isPrivate: json['isPrivate'] == true,
    );
  }

  int get remainingSeconds {
    final r = limitMinutes * 60 - usedSeconds;
    return r < 0 ? 0 : r;
  }
}

/// One row of the team inbox.
class SupportThreadSummary {
  final String userId;
  final String label;
  final bool isAccount;
  final String preview;
  final bool lastFromAdmin;
  final DateTime? lastMessageAt;
  final int unread;

  const SupportThreadSummary({
    required this.userId,
    required this.label,
    required this.isAccount,
    required this.preview,
    required this.lastFromAdmin,
    required this.lastMessageAt,
    required this.unread,
  });

  factory SupportThreadSummary.fromJson(Map<String, dynamic> json) {
    return SupportThreadSummary(
      userId: json['userId'] as String,
      label: json['label'] as String? ?? (json['userId'] as String),
      isAccount: json['isAccount'] == true,
      preview: json['preview'] as String? ?? '',
      lastFromAdmin: json['lastFromAdmin'] == true,
      lastMessageAt:
          DateTime.tryParse(json['lastMessageAt'] as String? ?? '')?.toLocal(),
      unread: (json['unread'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Response of `/api/support/thread`.
class SupportThreadPage {
  final bool isAdmin;
  final List<SupportMessage> messages;
  final SupportCustomer? customer;

  const SupportThreadPage({
    required this.isAdmin,
    required this.messages,
    this.customer,
  });
}
