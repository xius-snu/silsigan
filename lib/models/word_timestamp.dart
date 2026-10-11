class WordTimestamp {
  final String text;

  /// Where the word starts in the session's recording. Sessions saved by
  /// older versions hold Soniox-session times instead; see
  /// `wordsOnRecordingTimeline`.
  final int startMs;

  const WordTimestamp(this.text, this.startMs);

  Map<String, dynamic> toJson() => {'t': text, 's': startMs};

  factory WordTimestamp.fromJson(Map<String, dynamic> json) =>
      WordTimestamp(json['t'] as String, (json['s'] as num).toInt());
}
