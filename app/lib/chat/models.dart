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
enum VideoSource {
  catalog,
  youtube,
  none;

  /// Only the two sources the header labels; anything else is null.
  static VideoSource? parse(Object? s) => switch (s) {
    'catalog' => catalog,
    'youtube' => youtube,
    _ => null,
  };
}

List<Video> _videos(Object? list) => [
  for (final v in (list as List? ?? const []))
    Video.fromJson(v as Map<String, dynamic>),
];

int _count(Object? v) => v is num && v >= 0 ? v.toInt() : 0;

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.videos = const [],
    this.recommendations,
    this.pending = false,
    this.highlights = const [],
    this.latencyMs,
    this.source,
    this.command = false,
    this.model,
    this.promptTokens = 0,
    this.outputTokens = 0,
  });
  final Role role;
  final String text;
  final List<Video> videos;

  /// The reply's Recommended rail as stored by the server (OTTAI-22); null for
  /// replies made before it was stored (the app then asks per video).
  final List<Video>? recommendations;
  final bool pending;

  /// Key phrases to emphasise; always substrings of [text] (checked server-side).
  final List<String> highlights;

  /// Round trip of the request that produced this reply (fresh replies only).
  final int? latencyMs;
  final VideoSource? source;

  /// A player command's reply ("Paused.") — no model or tokens involved.
  final bool command;

  /// The model that wrote this reply; null when no LLM did (keyword fallback).
  final String? model;
  final int promptTokens;
  final int outputTokens;

  int get tokens => promptTokens + outputTokens;

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    role: j['role'] == 'user' ? Role.user : Role.assistant,
    text: j['content'] as String? ?? '',
    videos: _videos(j['videos']),
    recommendations: j['recommendations'] == null
        ? null
        : _videos(j['recommendations']),
    source: VideoSource.parse(j['source']),
    command: j['source'] == 'command',
    model: j['model'] as String?,
    promptTokens: _count(j['prompt_tokens']),
    outputTokens: _count(j['output_tokens']),
  );
}

/// An Ollama model the server allows, with the context window it is run with.
class ModelInfo {
  const ModelInfo(this.name, this.context);
  final String name;

  /// Tokens (num_ctx); 0 when unknown.
  final int context;

  factory ModelInfo.fromJson(Object? j) => j is Map
      ? ModelInfo(j['name'] as String, _count(j['context']))
      : ModelInfo(j as String, 0);
}

/// The chat's context meter and totals (OTTAI-27), as last reported by the server.
class ChatUsage {
  const ChatUsage({
    this.contextTokens = 0,
    this.contextLimit = 0,
    this.historyWindow = 6,
    this.trimmed = false,
  });

  /// Estimated prompt size the next request starts from.
  final int contextTokens;
  final int contextLimit;

  /// Only this many recent messages are sent to the model.
  final int historyWindow;

  /// Older messages had to be dropped to fit the context window.
  final bool trimmed;

  factory ChatUsage.fromJson(Map<String, dynamic> j) => ChatUsage(
    contextTokens: _count(j['context_tokens']),
    contextLimit: _count(j['context_limit']),
    historyWindow: _count(j['history_window']),
    trimmed: j['trimmed'] == true,
  );
}

/// Context windows the way models name them: 4096 → 4k, 131072 → 128k.
String compactContext(int n) =>
    n >= 1024 && n % 1024 == 0 ? '${n ~/ 1024}k' : compactTokens(n);

/// 412 · 1.2k · 34k
String compactTokens(int n) {
  if (n < 1000) return '$n';
  final k = (n / 1000).toStringAsFixed(n < 10000 ? 1 : 0);
  return '${k.endsWith('.0') ? k.substring(0, k.length - 2) : k}k';
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
    this.tokens = 0,
  });
  final String id;
  final String title;
  final DateTime updatedAt;

  /// Prompt plus output tokens used in the whole chat.
  final int tokens;

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: j['id'] as String,
    title: j['title'] as String? ?? 'Chat',
    updatedAt:
        DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.now(),
    tokens: _count(j['prompt_tokens']) + _count(j['output_tokens']),
  );
}

String formatTime(num seconds) {
  final s = seconds.isFinite ? seconds.floor() : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${r.toString().padLeft(2, '0')}';
}
