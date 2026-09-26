class Video {
  const Video({
    required this.youtubeId,
    required this.title,
    required this.channel,
    required this.durationS,
    required this.topic,
    required this.thumbnail,
    this.match,
  });

  final String youtubeId;
  final String title;
  final String channel;
  final int durationS;
  final String topic;
  final String thumbnail;

  /// 1–99: how close this video is to the question / the playing video.
  final int? match;

  static final _id = RegExp(r'^[A-Za-z0-9_-]{11}$');

  factory Video.fromJson(Map<String, dynamic> j) {
    final id = j['youtube_id'] as String;
    if (!_id.hasMatch(id)) throw const FormatException('bad video id');
    return Video(
      youtubeId: id,
      title: j['title'] as String? ?? '',
      channel: j['channel'] as String? ?? '',
      durationS: (j['duration_s'] as num?)?.toInt() ?? 0,
      topic: j['topic'] as String? ?? '',
      // Always build the thumbnail URL ourselves rather than trusting the payload.
      thumbnail: 'https://i.ytimg.com/vi/$id/mqdefault.jpg',
      match: switch (j['match']) {
        final num m when m >= 1 && m <= 99 => m.toInt(),
        _ => null,
      },
    );
  }
}

enum Role { user, assistant }

/// Where a reply's videos came from.
enum VideoSource { catalog, youtube, none }

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.videos = const [],
    this.pending = false,
    this.highlights = const [],
    this.latencyMs,
    this.source,
  });
  final Role role;
  final String text;
  final List<Video> videos;
  final bool pending;

  /// Key phrases to emphasise; always substrings of [text] (checked server-side).
  final List<String> highlights;

  /// Round trip of the request that produced this reply (fresh replies only).
  final int? latencyMs;
  final VideoSource? source;

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    role: j['role'] == 'user' ? Role.user : Role.assistant,
    text: j['content'] as String? ?? '',
    videos: [
      for (final v in (j['videos'] as List? ?? const []))
        Video.fromJson(v as Map<String, dynamic>),
    ],
  );
}

enum ActionType {
  seek,
  pause,
  play,
  stop,
  next,
  loop,
  unloop,
  mute,
  unmute,
  save,
}

class PlayerAction {
  const PlayerAction(this.type, [this.seconds = 0, this.start, this.end]);
  final ActionType type;
  final double seconds;

  /// Loop range; null for "loop this part" (the app picks the current chapter).
  final double? start;
  final double? end;

  static PlayerAction? fromJson(Object? j) {
    if (j is! Map) return null;
    final type = ActionType.values
        .where((a) => a.name == j['type'])
        .firstOrNull;
    if (type == null) return null;
    return PlayerAction(
      type,
      (j['seconds'] as num?)?.toDouble() ?? 0,
      (j['start'] as num?)?.toDouble(),
      (j['end'] as num?)?.toDouble(),
    );
  }
}

class Chapter {
  const Chapter(this.start, this.title);
  final double start;
  final String title;

  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
    (j['start_s'] as num?)?.toDouble() ?? 0,
    j['title'] as String? ?? '',
  );
}

/// The chapter playing at [t], or null.
int? chapterAt(List<Chapter> chapters, double t) {
  for (var i = chapters.length - 1; i >= 0; i--) {
    if (t >= chapters[i].start) return i;
  }
  return null;
}

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.updatedAt,
  });
  final String id;
  final String title;
  final DateTime updatedAt;

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: j['id'] as String,
    title: j['title'] as String? ?? 'Chat',
    updatedAt:
        DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.now(),
  );
}

String formatTime(num seconds) {
  final s = seconds.isFinite ? seconds.floor() : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${r.toString().padLeft(2, '0')}';
}
