class Video {
  const Video({
    required this.youtubeId,
    required this.title,
    required this.channel,
    required this.durationS,
    required this.topic,
    required this.thumbnail,
  });

  final String youtubeId;
  final String title;
  final String channel;
  final int durationS;
  final String topic;
  final String thumbnail;

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
    );
  }
}

enum Role { user, assistant }

class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.videos = const [], this.pending = false});
  final Role role;
  final String text;
  final List<Video> videos;
  final bool pending;

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        role: j['role'] == 'user' ? Role.user : Role.assistant,
        text: j['content'] as String? ?? '',
        videos: [for (final v in (j['videos'] as List? ?? const [])) Video.fromJson(v as Map<String, dynamic>)],
      );
}

enum ActionType { seek, pause, play, stop, next }

class PlayerAction {
  const PlayerAction(this.type, [this.seconds = 0]);
  final ActionType type;
  final double seconds;

  static PlayerAction? fromJson(Object? j) {
    if (j is! Map) return null;
    final type = ActionType.values.where((a) => a.name == j['type']).firstOrNull;
    if (type == null) return null;
    return PlayerAction(type, (j['seconds'] as num?)?.toDouble() ?? 0);
  }
}

class Conversation {
  const Conversation({required this.id, required this.title, required this.updatedAt});
  final String id;
  final String title;
  final DateTime updatedAt;

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Chat',
        updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.now(),
      );
}

String formatTime(num seconds) {
  final s = seconds.isFinite ? seconds.floor() : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${r.toString().padLeft(2, '0')}';
}
