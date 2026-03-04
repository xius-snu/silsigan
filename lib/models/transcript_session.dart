class TranscriptSession {
  final int? id;
  final String createdAt;
  final String koreanFull;
  final String vietnameseFull;
  final String koreanPreview;
  final String vietnamesePreview;

  const TranscriptSession({
    this.id,
    required this.createdAt,
    required this.koreanFull,
    required this.vietnameseFull,
    required this.koreanPreview,
    required this.vietnamesePreview,
  });

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'created_at': createdAt,
      'korean_full': koreanFull,
      'vietnamese_full': vietnameseFull,
      'korean_preview': koreanPreview,
      'vietnamese_preview': vietnamesePreview,
    };
  }

  factory TranscriptSession.fromMap(Map<String, dynamic> map) {
    return TranscriptSession(
      id: map['id'] as int?,
      createdAt: map['created_at'] as String,
      koreanFull: map['korean_full'] as String,
      vietnameseFull: map['vietnamese_full'] as String,
      koreanPreview: map['korean_preview'] as String,
      vietnamesePreview: map['vietnamese_preview'] as String,
    );
  }
}
