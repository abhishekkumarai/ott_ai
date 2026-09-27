class Video {
  const Video({
    required this.youtubeId,
    required this.title,
    required this.channel,
    required this.durationS,
    required this.topic,
    required this.thumbnail,
    this.match,
    this.provider = 'youtube',
    this.mediaType = 'video',
    this.season,
    this.episode,
  });

  final String youtubeId;
  final String title;
  final String channel;
  final int durationS;
  final String topic;
  final String thumbnail;

  /// 1–99: how close this video is to the question / the playing video.
  final int? match;
  final String provider; // 'youtube' | 'vidy'
  final String mediaType; // 'video' | 'movie' | 'tv' | 'anime'
  final int? season;
  final int? episode;

  static final _id = RegExp(
    r'^([A-Za-z0-9_-]{11}|[a-z0-9_-]+:(movie|tv|anime|video):[A-Za-z0-9_/-]+)$',
  );

  factory Video.fromJson(Map<String, dynamic> j) {
    final id = j['youtube_id'] as String;
    if (!_id.hasMatch(id)) throw const FormatException('bad video id');
    final provider =
        j['provider'] as String? ??
        (id.contains(':') ? id.split(':').first : 'youtube');
    final mediaType = j['media_type'] as String? ?? 'video';

    String thumb;
    if (provider != 'youtube') {
      final raw = j['thumbnail'] as String? ?? '';
      if (raw.startsWith('https://image.tmdb.org/') ||
          raw.startsWith('https://s4.anilist.co/')) {
        thumb = raw;
      } else {
        thumb = 'https://vidy.st/favicon.svg';
      }
    } else {
      thumb = 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
    }

    return Video(
      youtubeId: id,
      title: j['title'] as String? ?? '',
      channel: j['channel'] as String? ?? '',
      durationS: (j['duration_s'] as num?)?.toInt() ?? 0,
      topic: j['topic'] as String? ?? '',
      thumbnail: thumb,
      match: switch (j['match']) {
        final num m when m >= 1 && m <= 99 => m.toInt(),
        _ => null,
      },
      provider: provider,
      mediaType: mediaType,
      season: (j['season'] as num?)?.toInt(),
      episode: (j['episode'] as num?)?.toInt(),
    );
  }
}

enum Role { user, assistant }

/// Where a reply's videos came from.
enum VideoSource {
  catalog,
  youtube,
  vidy,
  multi,
  none;

  /// Only the sources the header labels; anything else is null.
  static VideoSource? parse(Object? s) => switch (s) {
    'catalog' => catalog,
    'youtube' => youtube,
    'vidy' => vidy,
    final String str when str.isNotEmpty => multi,
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

class Episode {
  const Episode({
    required this.youtubeId,
    required this.seriesId,
    required this.seriesTitle,
    required this.title,
    required this.episodeNumber,
    this.seasonNumber = 1,
    this.durationS = 0,
    this.thumbnail = '',
    this.overview = '',
    this.provider = 'vidy',
    this.mediaType = 'tv',
  });

  final String youtubeId;
  final String seriesId;
  final String seriesTitle;
  final String title;
  final int episodeNumber;
  final int seasonNumber;
  final int durationS;
  final String thumbnail;
  final String overview;
  final String provider;
  final String mediaType;

  Video toVideo({String? seriesName}) => Video(
    youtubeId: youtubeId,
    title: (seriesName != null && seriesName.isNotEmpty)
        ? '$seriesName - S${seasonNumber}E$episodeNumber: $title'
        : (seriesTitle.isNotEmpty)
            ? '$seriesTitle - S${seasonNumber}E$episodeNumber: $title'
            : 'S${seasonNumber}E$episodeNumber: $title',
    channel: (seriesName != null && seriesName.isNotEmpty)
        ? seriesName
        : (seriesTitle.isNotEmpty ? seriesTitle : 'TV Series'),
    durationS: durationS,
    topic: mediaType,
    thumbnail: thumbnail.isNotEmpty ? thumbnail : 'https://vidy.st/favicon.svg',
    provider: provider,
    mediaType: mediaType,
    season: seasonNumber,
    episode: episodeNumber,
  );

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
    youtubeId: j['youtube_id'] as String? ?? '',
    seriesId: j['series_id'] as String? ?? '',
    seriesTitle: j['series_title'] as String? ?? '',
    title: j['title'] as String? ?? '',
    episodeNumber: (j['episode_number'] as num?)?.toInt() ?? 1,
    seasonNumber: (j['season_number'] as num?)?.toInt() ?? 1,
    durationS: (j['duration_s'] as num?)?.toInt() ?? 0,
    thumbnail: j['thumbnail'] as String? ?? '',
    overview: j['overview'] as String? ?? '',
    provider: j['provider'] as String? ?? 'vidy',
    mediaType: j['media_type'] as String? ?? 'tv',
  );
}

class SeasonInfo {
  const SeasonInfo({
    required this.seasonNumber,
    this.name = '',
    this.episodeCount = 0,
  });

  final int seasonNumber;
  final String name;
  final int episodeCount;

  factory SeasonInfo.fromJson(Map<String, dynamic> j) => SeasonInfo(
    seasonNumber: (j['season_number'] as num?)?.toInt() ?? 1,
    name: j['name'] as String? ?? '',
    episodeCount: (j['episode_count'] as num?)?.toInt() ?? 0,
  );
}

class SeriesEpisodes {
  const SeriesEpisodes({
    required this.seriesId,
    required this.seriesTitle,
    this.mediaType = 'tv',
    this.currentSeason = 1,
    this.currentEpisode = 1,
    this.seasons = const [],
    this.episodes = const [],
  });

  final String seriesId;
  final String seriesTitle;
  final String mediaType;
  final int currentSeason;
  final int currentEpisode;
  final List<SeasonInfo> seasons;
  final List<Episode> episodes;

  factory SeriesEpisodes.fromJson(Map<String, dynamic> j) => SeriesEpisodes(
    seriesId: j['series_id'] as String? ?? '',
    seriesTitle: j['series_title'] as String? ?? '',
    mediaType: j['media_type'] as String? ?? 'tv',
    currentSeason: (j['current_season'] as num?)?.toInt() ?? 1,
    currentEpisode: (j['current_episode'] as num?)?.toInt() ?? 1,
    seasons: [
      for (final s in (j['seasons'] as List? ?? const []))
        SeasonInfo.fromJson(s as Map<String, dynamic>),
    ],
    episodes: [
      for (final e in (j['episodes'] as List? ?? const []))
        Episode.fromJson(e as Map<String, dynamic>),
    ],
  );
}

class StreamProviderInfo {
  const StreamProviderInfo({
    required this.id,
    required this.name,
    required this.category,
    required this.baseUrl,
    required this.searchType,
    this.status = 'healthy',
    this.embedAllowed = true,
    this.latencyMs = 0,
  });

  final String id;
  final String name;
  final String category;
  final String baseUrl;
  final String searchType;
  final String status;
  final bool embedAllowed;
  final int latencyMs;

  factory StreamProviderInfo.fromJson(Map<String, dynamic> j) =>
      StreamProviderInfo(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        category: j['category'] as String? ?? 'movies_tv',
        baseUrl: j['base_url'] as String? ?? '',
        searchType: j['search_type'] as String? ?? 'tmdb',
        status: j['status'] as String? ?? 'healthy',
        embedAllowed: j['embed_allowed'] as bool? ?? true,
        latencyMs: (j['latency_ms'] as num?)?.toInt() ?? 0,
      );
}


