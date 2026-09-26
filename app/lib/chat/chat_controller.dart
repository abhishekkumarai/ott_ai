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
/// "conversation:message:block". Untouched blocks follow the default (only the
/// latest reply open). Saved on the device, so reopening a chat — even after a
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
    this.model,
    this.nowPlaying,
    this.recommendations = const [],
    this.loadingRecommendations = false,
    this.played = const {},
    this.error,
  });

  final List<ChatMessage> messages;
  final String? conversationId;
  final bool sending;
  final List<String> models;
  final String? model;
  final Video? nowPlaying;
  final List<Video> recommendations;
  final bool loadingRecommendations;

  /// Videos already played in this chat (skipped by "next").
  final Set<String> played;
  final String? error;

  bool get playerOpen => nowPlaying != null;

  /// Index of the assistant reply the playing video belongs to (else the latest
  /// reply with videos). Its blocks are the "live" ones.
  int? get activeReplyIndex {
    int? latest;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != Role.assistant || m.videos.isEmpty) continue;
      latest ??= i;
      if (nowPlaying != null &&
          m.videos.any((v) => v.youtubeId == nowPlaying!.youtubeId)) {
        return i;
      }
    }
    return latest;
  }

  /// Alternatives for a reply: its other search results, plus (for the live reply)
  /// videos related to the one playing, highest match first within each group.
  List<Video> alternativesFor(int index) {
    final reply = messages[index].videos;
    final main = reply.firstOrNull;
    final seen = <String>{?main?.youtubeId, ?nowPlaying?.youtubeId};
    final out = <Video>[];
    for (final v in reply.skip(1)) {
      if (seen.add(v.youtubeId)) out.add(v);
    }
    if (index == activeReplyIndex) {
      for (final v in recommendations) {
        if (seen.add(v.youtubeId)) out.add(v);
      }
    }
    return out;
  }

  /// What "next" plays: unplayed alternatives of the live reply.
  List<Video> get upNext {
    final i = activeReplyIndex;
    final base = i == null ? recommendations : alternativesFor(i);
    return [
      for (final v in base)
        if (!played.contains(v.youtubeId)) v,
    ];
  }

  ChatState copyWith({
    List<ChatMessage>? messages,
    Object? conversationId = _keep,
    bool? sending,
    List<String>? models,
    Object? model = _keep,
    Object? nowPlaying = _keep,
    List<Video>? recommendations,
    bool? loadingRecommendations,
    Set<String>? played,
    Object? error = _keep,
  }) => ChatState(
    messages: messages ?? this.messages,
    conversationId: conversationId == _keep
        ? this.conversationId
        : conversationId as String?,
    sending: sending ?? this.sending,
    models: models ?? this.models,
    model: model == _keep ? this.model : model as String?,
    nowPlaying: nowPlaying == _keep ? this.nowPlaying : nowPlaying as Video?,
    recommendations: recommendations ?? this.recommendations,
    loadingRecommendations:
        loadingRecommendations ?? this.loadingRecommendations,
    played: played ?? this.played,
    error: error == _keep ? this.error : error as String?,
  );
}

const _keep = Object();

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
    // The saved model wins once both the model list and the preferences are in.
    ref.listen(preferencesProvider.select((p) => p.model), (_, m) {
      if (m != null && state.models.contains(m)) {
        state = state.copyWith(model: m);
      }
    });
    Future.microtask(loadModels);
    return const ChatState();
  }

  // ---------------------------------------------------------------- models
  Future<void> loadModels() async {
    try {
      final data = await _api.get('/models') as Map<String, dynamic>;
      if (!ref.mounted) return;
      final models = [for (final m in data['models'] as List) m as String];
      final def = data['default'] as String;
      final saved = _prefs.model;
      state = state.copyWith(
        models: models,
        model: models.contains(saved)
            ? saved
            : models.contains(state.model)
            ? state.model
            : (models.contains(def) ? def : models.firstOrNull),
      );
    } on ApiException {
      // Ollama down: chat still works via the keyword fallback.
    }
  }

  void setModel(String model) => state = state.copyWith(model: model);

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
      state = state.copyWith(
        conversationId: data['conversation_id'] as String?,
        messages: [
          ...state.messages,
          ChatMessage(
            role: Role.assistant,
            text: reply,
            videos: videos,
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
            source: switch (data['source']) {
              'catalog' => VideoSource.catalog,
              'youtube' => VideoSource.youtube,
              _ => null,
            },
          ),
        ],
        sending: false,
      );
      if (action != null) {
        apply(action);
      } else if (videos.isNotEmpty) {
        play(videos.first);
      }
    } on ApiException catch (e) {
      if (ref.mounted) state = state.copyWith(sending: false, error: e.message);
    }
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
        ChatMessage(role: Role.assistant, text: _stoppedText()),
      ],
    );
    _close();
  }

  void play(Video v, {double start = 0}) {
    _started = false;
    _playback.set(Playback(d: v.durationS.toDouble(), t: start));
    state = state.copyWith(
      nowPlaying: v,
      recommendations: const [],
      loadingRecommendations: true,
      played: {...state.played, v.youtubeId},
    );
    _player.load(v.youtubeId, start: start);
    final prefs = _prefs;
    if (prefs.playbackRate != 1) _player.setRate(prefs.playbackRate);
    if (prefs.startMuted) _player.mute();
    unawaited(
      _api.post('/videos/${v.youtubeId}/watched').catchError((_) => null),
    );
    unawaited(_loadRecommendations(v));
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

  Future<void> _loadRecommendations(Video v) async {
    try {
      final data =
          await _api.get('/videos/${v.youtubeId}/recommendations') as List;
      if (!ref.mounted || state.nowPlaying?.youtubeId != v.youtubeId) return;
      state = state.copyWith(
        recommendations: [
          for (final r in data) Video.fromJson(r as Map<String, dynamic>),
        ],
        loadingRecommendations: false,
      );
    } on ApiException {
      if (ref.mounted) state = state.copyWith(loadingRecommendations: false);
    }
  }

  String _stoppedText() {
    final t = ref.read(playbackProvider).t;
    return t > 0
        ? 'Stopped at ${formatTime(t)}. Back to chat.'
        : 'Stopped. Back to chat.';
  }

  void _close() {
    _player.stop();
    state = state.copyWith(nowPlaying: null, recommendations: const []);
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
    state = state.copyWith(
      conversationId: c.id,
      messages: [
        for (final m in data) ChatMessage.fromJson(m as Map<String, dynamic>),
      ],
      played: const {},
      error: null,
    );
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
