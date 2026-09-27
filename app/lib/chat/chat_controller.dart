import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api.dart';
import '../auth/auth.dart';
import '../config.dart';
import '../library/saved.dart';
import '../player/player_handle.dart';
import '../player/player_view.dart';
import '../settings/preferences.dart';
import 'models.dart';

/// Builds the platform player. Overridden in widget tests (no browser/WebView there).
///
/// One GlobalKey for the app's lifetime: switching between theater and the
/// mini-player reparents the same view, so the video keeps playing without reloading.
final playerViewBuilderProvider = Provider<Widget Function(PlayerHandle)>((
  ref,
) {
  final key = GlobalKey(debugLabel: 'player');
  return (h) => PlayerView(key: key, handle: h);
});

/// Mini-player (chat stays in front) or theater (large player). Starts from the
/// user's saved default and then remembers the last choice for the session.
class PlayerModeController extends Notifier<PlayerMode> {
  bool _touched = false;

  @override
  PlayerMode build() {
    ref.listen(preferencesProvider.select((p) => p.playerMode), (_, m) {
      if (!_touched) state = m;
    });
    return ref.read(preferencesProvider).playerMode;
  }

  void set(PlayerMode m) {
    _touched = true;
    state = m;
  }

  void toggle() =>
      set(state == PlayerMode.mini ? PlayerMode.theater : PlayerMode.mini);
}

final playerModeProvider = NotifierProvider<PlayerModeController, PlayerMode>(
  PlayerModeController.new,
);

final playerHandleProvider = Provider<PlayerHandle>((ref) {
  final h = PlayerHandle();
  ref.onDispose(h.dispose);
  return h;
});

/// Chapters parsed server-side from the video description; cached per video.
final chaptersProvider = FutureProvider.family<List<Chapter>, String>((
  ref,
  youtubeId,
) async {
  ref.keepAlive();
  try {
    final data = await ref.read(apiProvider).get('/videos/$youtubeId/chapters');
    return [
      for (final c in data as List) Chapter.fromJson(c as Map<String, dynamic>),
    ];
  } on ApiException {
    return const [];
  }
});

/// Where manual collapse toggles are kept between app runs (OTTAI-18).
abstract class CollapseStore {
  Future<Map<String, bool>> load();
  Future<void> save(Map<String, bool> entries);
}

/// localStorage on web, platform preferences on Android/Windows.
class PrefsCollapseStore implements CollapseStore {
  static const _key = 'ott_ai.collapse';

  @override
  Future<Map<String, bool>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return {};
      final data = jsonDecode(raw);
      if (data is! Map) return {};
      return {
        for (final e in data.entries)
          if (e.key is String && e.value is bool)
            e.key as String: e.value as bool,
      };
    } catch (_) {
      return {}; // corrupt or unavailable storage: start fresh
    }
  }

  @override
  Future<void> save(Map<String, bool> entries) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode(entries),
      );
    } catch (_) {
      // Storage unavailable (private mode etc.): keep it for the session only.
    }
  }
}

final collapseStoreProvider = Provider<CollapseStore>(
  (ref) => PrefsCollapseStore(),
);

/// Open/closed state of collapsible blocks the user toggled by hand, keyed by
/// "conversation:message:block". Untouched blocks start closed. Saved on the
/// device, so reopening a chat — even after a
/// restart — restores it. Unsaved ("new") chats aren't stored.
class CollapseController extends Notifier<Map<String, bool>> {
  /// Most recent toggles kept on disk.
  static const maxEntries = 500;

  @override
  Map<String, bool> build() {
    Future.microtask(() async {
      final saved = await ref.read(collapseStoreProvider).load();
      if (!ref.mounted || saved.isEmpty) return;
      // Toggles made while loading win over stored ones.
      state = {...saved, ...state};
    });
    return const {};
  }

  void set(String key, bool open) {
    // Re-insert so the map's order is "least recently toggled first".
    final next = {...state}..remove(key);
    next[key] = open;
    while (next.length > maxEntries) {
      next.remove(next.keys.first);
    }
    state = next;
    if (key.startsWith('new:')) return;
    final persisted = {
      for (final e in next.entries)
        if (!e.key.startsWith('new:')) e.key: e.value,
    };
    unawaited(ref.read(collapseStoreProvider).save(persisted));
  }
}

final collapseProvider =
    NotifierProvider<CollapseController, Map<String, bool>>(
      CollapseController.new,
    );

class Playback {
  const Playback({
    this.t = 0,
    this.d = 0,
    this.playing = false,
    this.muted = false,
    this.volume = 100,
    this.rate = 1,
    this.quality = '',
    this.captions = false,
    this.loopStart,
    this.loopEnd,
    this.error,
  });
  final double t;
  final double d;
  final bool playing;
  final bool muted;
  final double volume;
  final double rate;
  final String quality;
  final bool captions;
  final double? loopStart;
  final double? loopEnd;
  final String? error;

  bool get looping => loopStart != null && loopEnd != null;

  Playback copyWith({
    double? t,
    double? d,
    bool? playing,
    bool? muted,
    double? volume,
    double? rate,
    String? quality,
    bool? captions,
    Object? loopStart = _keep,
    Object? loopEnd = _keep,
    String? error,
  }) => Playback(
    t: t ?? this.t,
    d: d ?? this.d,
    playing: playing ?? this.playing,
    muted: muted ?? this.muted,
    volume: volume ?? this.volume,
    rate: rate ?? this.rate,
    quality: quality ?? this.quality,
    captions: captions ?? this.captions,
    loopStart: loopStart == _keep ? this.loopStart : loopStart as double?,
    loopEnd: loopEnd == _keep ? this.loopEnd : loopEnd as double?,
    error: error,
  );
}

class PlaybackController extends Notifier<Playback> {
  @override
  Playback build() => const Playback();
  void set(Playback p) => state = p;
}

final playbackProvider = NotifierProvider<PlaybackController, Playback>(
  PlaybackController.new,
);

class ChatState {
  const ChatState({
    this.messages = const [],
    this.conversationId,
    this.sending = false,
    this.models = const [],
    this.defaultModel,
    this.model,
    this.baseContext = 0,
    this.usage,
    this.nowPlaying,
    this.railReply,
    this.related = const {},
    this.loadingRelated = const {},
    this.played = const {},
    this.error,
  });

  final List<ChatMessage> messages;
  final String? conversationId;
  final bool sending;
  final List<ModelInfo> models;

  /// The server's default model (used when no preference is saved).
  final String? defaultModel;

  /// The model answering in this chat (switchable per chat, OTTAI-27).
  final String? model;

  /// Context meter of a chat with nothing sent yet.
  final int baseContext;
  final ChatUsage? usage;
  final Video? nowPlaying;

  /// An earlier reply whose recommendations the rail shows ("Show
  /// recommendations"); null = the latest reply with videos (OTTAI-24).
  final int? railReply;

  /// Related videos per video id, looked up for replies that have no stored
  /// recommendations (made before they were stored); kept for the session.
  final Map<String, List<Video>> related;
  final Set<String> loadingRelated;

  /// Videos already played in this chat (skipped by "next", "Watched" on the rail).
  final Set<String> played;
  final String? error;

  bool get playerOpen => nowPlaying != null;

  bool get hasVideos => latestReplyIndex != null;

  /// The newest assistant reply with videos.
  int? get latestReplyIndex {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == Role.assistant && m.videos.isNotEmpty) return i;
    }
    return null;
  }

  /// The reply the Recommended rail shows.
  int? get railIndex {
    final r = railReply;
    if (r != null && r < messages.length && messages[r].videos.isNotEmpty) {
      return r;
    }
    return latestReplyIndex;
  }

  /// The rail shows an earlier reply rather than the latest one.
  bool get railShowsEarlier {
    final i = railIndex;
    return i != null && i != latestReplyIndex;
  }

  /// Index of the assistant reply the playing video belongs to (else the latest
  /// reply with videos). Its blocks are the "live" ones.
  int? get activeReplyIndex {
    if (nowPlaying != null) {
      for (var i = messages.length - 1; i >= 0; i--) {
        final m = messages[i];
        if (m.role == Role.assistant &&
            m.videos.any((v) => v.youtubeId == nowPlaying!.youtubeId)) {
          return i;
        }
      }
    }
    return latestReplyIndex;
  }

  /// Recommendations for reply [index]: stored with the reply, else its other
  /// search results plus the videos related to its main one — no duplicates,
  /// main video left out, best match first.
  List<Video> recommendationsFor(int index) {
    if (index < 0 || index >= messages.length) return const [];
    final m = messages[index];
    final main = m.videos.firstOrNull;
    if (main == null) return const [];
    final stored = m.recommendations;
    if (stored != null) {
      return [
        for (final v in stored)
          if (v.youtubeId != main.youtubeId) v,
      ];
    }
    return mergeRecommendations(m.videos, related[main.youtubeId] ?? const []);
  }

  /// Still waiting for the related videos of reply [index].
  bool loadingFor(int index) {
    if (index < 0 || index >= messages.length) return false;
    final m = messages[index];
    final main = m.videos.firstOrNull;
    return m.recommendations == null &&
        main != null &&
        loadingRelated.contains(main.youtubeId);
  }

  List<Video> get rail {
    final i = railIndex;
    return i == null ? const [] : recommendationsFor(i);
  }

  /// What "next" plays: the rail's unplayed rows, top first.
  List<Video> get upNext => [
    for (final v in rail)
      if (!played.contains(v.youtubeId) && v.youtubeId != nowPlaying?.youtubeId)
        v,
  ];

  /// Tokens used in this chat (prompt plus output, as Ollama reported them).
  int get tokensUsed => messages.fold(0, (sum, m) => sum + m.tokens);

  /// Context window of the chat's model.
  int get contextLimit {
    final known = models.where((m) => m.name == model).firstOrNull?.context;
    return (known ?? 0) > 0 ? known! : (usage?.contextLimit ?? 0);
  }

  int get contextTokens => usage?.contextTokens ?? baseContext;

  ChatState copyWith({
    List<ChatMessage>? messages,
    Object? conversationId = _keep,
    bool? sending,
    List<ModelInfo>? models,
    Object? defaultModel = _keep,
    Object? model = _keep,
    int? baseContext,
    Object? usage = _keep,
    Object? nowPlaying = _keep,
    Object? railReply = _keep,
    Map<String, List<Video>>? related,
    Set<String>? loadingRelated,
    Set<String>? played,
    Object? error = _keep,
  }) => ChatState(
    messages: messages ?? this.messages,
    conversationId: conversationId == _keep
        ? this.conversationId
        : conversationId as String?,
    sending: sending ?? this.sending,
    models: models ?? this.models,
    defaultModel: defaultModel == _keep
        ? this.defaultModel
        : defaultModel as String?,
    model: model == _keep ? this.model : model as String?,
    baseContext: baseContext ?? this.baseContext,
    usage: usage == _keep ? this.usage : usage as ChatUsage?,
    nowPlaying: nowPlaying == _keep ? this.nowPlaying : nowPlaying as Video?,
    railReply: railReply == _keep ? this.railReply : railReply as int?,
    related: related ?? this.related,
    loadingRelated: loadingRelated ?? this.loadingRelated,
    played: played ?? this.played,
    error: error == _keep ? this.error : error as String?,
  );
}

const _keep = Object();

/// A reply's other results plus [related], without duplicates or the main video
/// (the first of [videos]), highest match first (unscored last, order kept).
List<Video> mergeRecommendations(List<Video> videos, List<Video> related) {
  final main = videos.firstOrNull?.youtubeId;
  final seen = <String>{?main};
  final out = <Video>[
    for (final v in [...videos.skip(1), ...related])
      if (seen.add(v.youtubeId)) v,
  ];
  // List.sort isn't guaranteed stable; sort by (match desc, original position).
  final order = {for (final (i, v) in out.indexed) v.youtubeId: i};
  out.sort((a, b) {
    final c = (b.match ?? 0).compareTo(a.match ?? 0);
    return c != 0 ? c : order[a.youtubeId]!.compareTo(order[b.youtubeId]!);
  });
  return out;
}

class ChatController extends Notifier<ChatState> {
  StreamSubscription<PlayerEvent>? _sub;

  /// The current video has reported playback at least once. A later "ready"
  /// means the player view was recreated (e.g. after visiting Settings), so the
  /// video is reloaded where it was.
  bool _started = false;

  ApiClient get _api => ref.read(apiProvider);
  PlayerHandle get _player => ref.read(playerHandleProvider);
  PlaybackController get _playback => ref.read(playbackProvider.notifier);
  Preferences get _prefs => ref.read(preferencesProvider);

  @override
  ChatState build() {
    _sub = _player.events.listen(_onPlayerEvent);
    ref.onDispose(() => _sub?.cancel());
    listenSelf((prev, next) {
      if (prev?.conversationId != next.conversationId) {
        ref.read(openChatIdProvider.notifier).set(next.conversationId);
      }
    });
    // The saved model wins once both the model list and the preferences are in
    // (for a new chat; an open chat keeps the model it was switched to).
    ref.listen(preferencesProvider.select((p) => p.model), (_, m) {
      if (m != null && _has(m) && state.messages.isEmpty) {
        state = state.copyWith(model: m);
      }
    });
    Future.microtask(loadModels);
    return const ChatState();
  }

  // ---------------------------------------------------------------- models
  bool _has(String? m) => state.models.any((x) => x.name == m);

  /// Model for a chat with no model of its own: the saved one, else the default.
  String? _startModel() {
    final saved = _prefs.model;
    if (_has(saved)) return saved;
    if (_has(state.defaultModel)) return state.defaultModel;
    return state.models.firstOrNull?.name;
  }

  Future<void> loadModels() async {
    try {
      final data = await _api.get('/models') as Map<String, dynamic>;
      if (!ref.mounted) return;
      state = state.copyWith(
        models: [for (final m in data['models'] as List) ModelInfo.fromJson(m)],
        defaultModel: data['default'] as String?,
        baseContext: (data['base_context'] as num?)?.toInt() ?? 0,
      );
      if (!_has(state.model)) state = state.copyWith(model: _startModel());
    } on ApiException {
      // Ollama down: chat still works via the keyword fallback.
    }
  }

  /// Switch the model answering in this chat (Settings also sets the default).
  void setModel(String model) {
    state = state.copyWith(model: model);
    unawaited(_loadUsage());
  }

  /// Context meter and trim flag for the open chat and its model.
  Future<void> _loadUsage() async {
    final id = state.conversationId;
    final model = state.model;
    if (id == null) return;
    try {
      final data =
          await _api.get('/conversations/$id/usage', {'model': ?model})
              as Map<String, dynamic>;
      if (!ref.mounted || state.conversationId != id) return;
      state = state.copyWith(usage: ChatUsage.fromJson(data));
    } on ApiException {
      // The meter keeps its last value.
    }
  }

  // ---------------------------------------------------------------- chat
  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || state.sending) return;
    final clipped = text.length > 500 ? text.substring(0, 500) : text;
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(role: Role.user, text: clipped),
      ],
      sending: true,
      error: null,
    );
    final watch = Stopwatch()..start();
    try {
      final data =
          await _api.post('/chat', {
                'message': clipped,
                'conversation_id': ?state.conversationId,
                'model': ?state.model,
                'player_open': state.playerOpen,
              })
              as Map<String, dynamic>;
      if (!ref.mounted) return;
      final videos = [
        for (final v in (data['videos'] as List? ?? const []))
          Video.fromJson(v as Map<String, dynamic>),
      ];
      final action = PlayerAction.fromJson(data['action']);
      var reply = data['reply'] as String? ?? '';
      if (action?.type == ActionType.stop) reply = _stoppedText();
      final usage = data['usage'];
      state = state.copyWith(
        conversationId: data['conversation_id'] as String?,
        messages: [
          ...state.messages,
          ChatMessage(
            role: Role.assistant,
            text: reply,
            videos: videos,
            recommendations: videos.isEmpty
                ? null
                : [
                    for (final v in (data['recommendations'] as List? ?? []))
                      Video.fromJson(v as Map<String, dynamic>),
                  ],
            highlights: [
              for (final h in (data['highlights'] as List? ?? const []))
                if (h is String &&
                    RegExp(
                      RegExp.escape(h),
                      caseSensitive: false,
                    ).hasMatch(reply))
                  h,
            ],
            latencyMs: videos.isEmpty ? null : watch.elapsedMilliseconds,
            source: VideoSource.parse(data['source']),
            command: data['source'] == 'command',
            model: data['model'] as String?,
            promptTokens: (data['prompt_tokens'] as num?)?.toInt() ?? 0,
            outputTokens: (data['output_tokens'] as num?)?.toInt() ?? 0,
          ),
        ],
        // A new reply with videos moves the rail on to it.
        railReply: videos.isEmpty ? state.railReply : null,
        usage: usage is Map<String, dynamic>
            ? ChatUsage.fromJson(usage)
            : state.usage,
        sending: false,
      );
      // Replies only suggest videos; the user picks what to play.
      if (action != null) apply(action);
    } on ApiException catch (e) {
      if (ref.mounted) state = state.copyWith(sending: false, error: e.message);
    }
  }

  /// "Summarize this part" (OTTAI-20): the local model summarises the transcript
  /// between [start] and [end]; the exchange is saved in the chat.
  Future<void> summarize({
    required Video video,
    double? start,
    double? end,
    required String label,
  }) async {
    if (state.sending) return;
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(role: Role.user, text: 'Summarize “$label”'),
      ],
      sending: true,
      error: null,
    );
    try {
      final data =
          await _api.post('/videos/${video.youtubeId}/summary', {
                'start_s': ?start,
                'end_s': ?end,
                'label': label,
                'model': ?state.model,
                'conversation_id': ?state.conversationId,
              })
              as Map<String, dynamic>;
      if (!ref.mounted) return;
      state = state.copyWith(
        messages: [
          ...state.messages,
          ChatMessage(
            role: Role.assistant,
            text: data['summary'] as String? ?? '',
            model: data['model'] as String?,
            promptTokens: (data['prompt_tokens'] as num?)?.toInt() ?? 0,
            outputTokens: (data['output_tokens'] as num?)?.toInt() ?? 0,
          ),
        ],
        sending: false,
      );
      unawaited(_loadUsage());
    } on ApiException catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        // Drop the request line again so the chat doesn't show an unanswered ask.
        messages: state.messages.sublist(0, state.messages.length - 1),
        sending: false,
        error: e.message,
      );
    }
  }

  // ---------------------------------------------------------------- rail
  /// "Show recommendations" on an earlier reply: the rail shows its list.
  void showRecommendationsFor(int index) {
    state = state.copyWith(
      railReply: index == state.latestReplyIndex ? null : index,
    );
    unawaited(ensureRecommendations(index));
  }

  void backToLatest() => state = state.copyWith(railReply: null);

  /// Replies made before recommendations were stored ask the server for the
  /// videos related to their main one (once per video per session).
  Future<void> ensureRecommendations(int index) async {
    if (index < 0 || index >= state.messages.length) return;
    final m = state.messages[index];
    final main = m.videos.firstOrNull;
    if (main == null || m.recommendations != null) return;
    final id = main.youtubeId;
    if (state.related.containsKey(id) || state.loadingRelated.contains(id)) {
      return;
    }
    state = state.copyWith(loadingRelated: {...state.loadingRelated, id});
    List<Video> found = const [];
    try {
      final data = await _api.get('/videos/$id/recommendations') as List;
      found = [for (final r in data) Video.fromJson(r as Map<String, dynamic>)];
    } on ApiException {
      // Shown as "no recommendations"; not retried this session.
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      related: {...state.related, id: found},
      loadingRelated: {...state.loadingRelated}..remove(id),
    );
  }

  // ---------------------------------------------------------------- player
  void apply(PlayerAction a) {
    if (!state.playerOpen) return;
    switch (a.type) {
      case ActionType.seek:
        _player.seekBy(a.seconds);
      case ActionType.pause:
        _player.pause();
      case ActionType.play:
        _player.play();
      case ActionType.stop:
        _close();
      case ActionType.next:
        next();
      case ActionType.loop:
        if (a.start != null && a.end != null) {
          loop(a.start!, a.end!);
        } else {
          loopCurrentPart();
        }
      case ActionType.unloop:
        unloop();
      case ActionType.mute:
        _player.mute();
      case ActionType.unmute:
        unmute();
      case ActionType.save:
        final v = state.nowPlaying;
        if (v != null) {
          unawaited(
            ref.read(savedProvider.notifier).save(v).catchError((_) {}),
          );
        }
    }
  }

  /// Local controls (buttons / keyboard) skip the server round-trip entirely.
  void forward([double s = 25]) => apply(PlayerAction(ActionType.seek, s));
  void back([double s = 25]) => apply(PlayerAction(ActionType.seek, -s));
  void togglePause() => apply(
    PlayerAction(
      ref.read(playbackProvider).playing ? ActionType.pause : ActionType.play,
    ),
  );

  void seekTo(double seconds) {
    if (state.playerOpen) _player.seekTo(seconds);
  }

  void setVolume(double v) => _player.setVolume(v);
  void setRate(double r) => _player.setRate(r);

  void toggleMute() =>
      ref.read(playbackProvider).muted ? unmute() : _player.mute();

  /// Web only (see [canFullscreen]).
  void fullscreen() {
    if (state.playerOpen) _player.fullscreen();
  }

  void toggleCaptions() =>
      _player.captions(!ref.read(playbackProvider).captions);

  void stopFromUi() {
    if (!state.playerOpen) return;
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(role: Role.assistant, text: _stoppedText(), command: true),
      ],
    );
    _close();
  }

  void play(Video v, {double start = 0}) {
    _started = false;
    _playback.set(Playback(d: v.durationS.toDouble(), t: start));
    state = state.copyWith(
      nowPlaying: v,
      played: {...state.played, v.youtubeId},
    );
    _player.load(v.youtubeId, start: start);
    final prefs = _prefs;
    if (prefs.playbackRate != 1) _player.setRate(prefs.playbackRate);
    if (prefs.startMuted) _player.mute();
    unawaited(
      _api.post('/videos/${v.youtubeId}/watched').catchError((_) => null),
    );
  }

  void next() {
    final queue = state.upNext;
    if (queue.isNotEmpty) play(queue.first);
  }

  void unmute() {
    _player.unmute();
    _playback.set(ref.read(playbackProvider).copyWith(muted: false));
  }

  // ---------------------------------------------------------------- looping
  void loop(double start, double end) {
    final d = ref.read(playbackProvider).d;
    final b = d > 0 ? end.clamp(0, d).toDouble() : end;
    if (b - start < 1) return;
    _player.loop(start, b);
  }

  /// "Loop this part": the current chapter, else 30 seconds around the playhead.
  void loopCurrentPart() {
    final v = state.nowPlaying;
    if (v == null) return;
    final p = ref.read(playbackProvider);
    final chapters = ref.read(chaptersProvider(v.youtubeId)).value ?? const [];
    final i = chapterAt(chapters, p.t);
    if (i != null) {
      final end = i + 1 < chapters.length
          ? chapters[i + 1].start
          : (p.d > 0 ? p.d : chapters[i].start + 60);
      loop(chapters[i].start, end);
    } else {
      final start = (p.t - 15).clamp(0, double.infinity).toDouble();
      loop(start, start + 30);
    }
  }

  void unloop() => _player.unloop();

  String _stoppedText() {
    final t = ref.read(playbackProvider).t;
    return t > 0
        ? 'Stopped at ${formatTime(t)}. Back to chat.'
        : 'Stopped. Back to chat.';
  }

  void _close() {
    _player.stop();
    // Recommendations stay: they belong to the replies, not to playback.
    state = state.copyWith(nowPlaying: null);
    _playback.set(const Playback());
  }

  void _onPlayerEvent(PlayerEvent e) {
    final p = ref.read(playbackProvider);
    switch (e.type) {
      case 'ready':
        final v = state.nowPlaying;
        if (v != null && _started) {
          _player.load(v.youtubeId, start: p.t);
          // The new player starts fresh: restore speed, mute and loop.
          if (p.rate != 1) _player.setRate(p.rate);
          if (p.muted) _player.mute();
          if (p.looping) _player.loop(p.loopStart!, p.loopEnd!);
          // Not playing until the new player says so (autoplay may be blocked).
          _playback.set(p.copyWith(playing: false, error: p.error));
        }
      case 'time' || 'state' || 'stopped' || 'ended':
        if (e.type == 'time' && state.nowPlaying != null) _started = true;
        _playback.set(
          p.copyWith(
            t: e.t,
            d: e.d > 0 ? e.d : p.d,
            playing: e.playing,
            muted: e.muted,
            volume: e.volume,
            rate: e.rate,
            quality: e.quality,
            captions: e.captions,
            loopStart: e.hasLoop ? e.loopA : p.loopStart,
            loopEnd: e.hasLoop ? e.loopB : p.loopEnd,
            error: p.error,
          ),
        );
        // A loop repeats rather than moving on (player.js normally catches the
        // end itself; this guards the Dart side too).
        if (e.type == 'ended' && _prefs.autoplayNext && !p.looping) next();
      case 'muted':
        _playback.set(p.copyWith(muted: true, error: p.error));
      case 'error':
        _playback.set(
          p.copyWith(
            playing: false,
            error: e.message ?? 'This video can’t be played here.',
          ),
        );
    }
  }

  // ---------------------------------------------------------------- history
  Future<List<Conversation>> conversations() async {
    final data = await _api.get('/conversations') as List;
    return [
      for (final c in data) Conversation.fromJson(c as Map<String, dynamic>),
    ];
  }

  Future<void> open(Conversation c) async {
    _close();
    final data = await _api.get('/conversations/${c.id}/messages') as List;
    if (!ref.mounted) return;
    final messages = [
      for (final m in data) ChatMessage.fromJson(m as Map<String, dynamic>),
    ];
    // The chat keeps answering with the model it last used, if still offered.
    final last = messages.reversed
        .where((m) => m.role == Role.assistant && m.model != null)
        .firstOrNull
        ?.model;
    state = state.copyWith(
      conversationId: c.id,
      messages: messages,
      model: _has(last) ? last : _startModel(),
      usage: null,
      railReply: null,
      played: const {},
      error: null,
    );
    final latest = state.latestReplyIndex;
    if (latest != null) unawaited(ensureRecommendations(latest));
    unawaited(_loadUsage());
  }

  Future<void> deleteConversation(String id) async {
    await _api.delete('/conversations/$id');
    if (state.conversationId == id) newChat();
  }

  Future<void> deleteAllConversations() async {
    await _api.delete('/conversations');
    newChat();
  }

  void newChat() {
    _close();
    state = state.copyWith(
      messages: const [],
      conversationId: null,
      model: _startModel() ?? state.model,
      usage: null,
      railReply: null,
      played: const {},
      error: null,
    );
  }
}

final chatProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

double get seekStep => AppConfig.seekStep.toDouble();

/// Native WebViews use YouTube's own fullscreen button instead.
bool get canFullscreen => kIsWeb;
