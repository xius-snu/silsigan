class WordTimestamp {
  final String text;
  final int startMs;

  const WordTimestamp(this.text, this.startMs);

  Map<String, dynamic> toJson() => {'t': text, 's': startMs};

  factory WordTimestamp.fromJson(Map<String, dynamic> json) =>
      WordTimestamp(json['t'] as String, json['s'] as int);
}
