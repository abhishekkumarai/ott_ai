import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api.dart';
import '../auth/auth.dart';
import '../config.dart';
import '../player/player_handle.dart';
import '../player/player_view.dart';
import 'models.dart';

/// Builds the platform player. Overridden in widget tests (no browser/WebView there).
final playerViewBuilderProvider = Provider<Widget Function(PlayerHandle)>(
  (ref) =>
      (h) => PlayerView(key: const ValueKey('player'), handle: h),
);

final playerHandleProvider = Provider<PlayerHandle>((ref) {
  final h = PlayerHandle();
  ref.onDispose(h.dispose);
  return h;
});

class Playback {
  const Playback({
    this.t = 0,
    this.d = 0,
    this.playing = false,
    this.muted = false,
    this.error,
  });
  final double t;
  final double d;
  final bool playing;
  final bool muted;
  final String? error;

  Playback copyWith({
    double? t,
    double? d,
    bool? playing,
    bool? muted,
    String? error,
  }) => Playback(
    t: t ?? this.t,
    d: d ?? this.d,
    playing: playing ?? this.playing,
    muted: muted ?? this.muted,
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
  final String? error;

  bool get playerOpen => nowPlaying != null;

  ChatState copyWith({
    List<ChatMessage>? messages,
    Object? conversationId = _keep,
    bool? sending,
    List<String>? models,
    Object? model = _keep,
    Object? nowPlaying = _keep,
    List<Video>? recommendations,
    bool? loadingRecommendations,
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
    error: error == _keep ? this.error : error as String?,
  );
}

const _keep = Object();

class ChatController extends Notifier<ChatState> {
  StreamSubscription<PlayerEvent>? _sub;

  ApiClient get _api => ref.read(apiProvider);
  PlayerHandle get _player => ref.read(playerHandleProvider);
  PlaybackController get _playback => ref.read(playbackProvider.notifier);

  @override
  ChatState build() {
    _sub = _player.events.listen(_onPlayerEvent);
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(loadModels);
    return const ChatState();
  }

  // ---------------------------------------------------------------- models
  Future<void> loadModels() async {
    try {
      final data = await _api.get('/models') as Map<String, dynamic>;
      final models = [for (final m in data['models'] as List) m as String];
      final def = data['default'] as String;
      state = state.copyWith(
        models: models,
        model: models.contains(state.model)
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
    try {
      final data =
          await _api.post('/chat', {
                'message': clipped,
                'conversation_id': ?state.conversationId,
                'model': ?state.model,
                'player_open': state.playerOpen,
              })
              as Map<String, dynamic>;
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
          ChatMessage(role: Role.assistant, text: reply, videos: videos),
        ],
        sending: false,
      );
      if (action != null) {
        apply(action);
      } else if (videos.isNotEmpty) {
        play(videos.first);
      }
    } on ApiException catch (e) {
      state = state.copyWith(sending: false, error: e.message);
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

  void play(Video v) {
    _playback.set(Playback(d: v.durationS.toDouble()));
    state = state.copyWith(
      nowPlaying: v,
      recommendations: const [],
      loadingRecommendations: true,
    );
    _player.load(v.youtubeId);
    unawaited(
      _api.post('/videos/${v.youtubeId}/watched').catchError((_) => null),
    );
    unawaited(_loadRecommendations(v));
  }

  void next() {
    final recs = state.recommendations;
    if (recs.isNotEmpty) play(recs.first);
  }

  void unmute() {
    _player.unmute();
    _playback.set(ref.read(playbackProvider).copyWith(muted: false));
  }

  Future<void> _loadRecommendations(Video v) async {
    try {
      final data =
          await _api.get('/videos/${v.youtubeId}/recommendations') as List;
      if (state.nowPlaying?.youtubeId != v.youtubeId) return;
      state = state.copyWith(
        recommendations: [
          for (final r in data) Video.fromJson(r as Map<String, dynamic>),
        ],
        loadingRecommendations: false,
      );
    } on ApiException {
      state = state.copyWith(loadingRecommendations: false);
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
  }

  void _onPlayerEvent(PlayerEvent e) {
    final p = ref.read(playbackProvider);
    switch (e.type) {
      case 'time' || 'state' || 'stopped' || 'ended':
        _playback.set(
          p.copyWith(
            t: e.t,
            d: e.d > 0 ? e.d : p.d,
            playing: e.playing,
            error: p.error,
          ),
        );
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
    state = state.copyWith(
      conversationId: c.id,
      messages: [
        for (final m in data) ChatMessage.fromJson(m as Map<String, dynamic>),
      ],
      error: null,
    );
  }

  Future<void> deleteConversation(String id) async {
    await _api.delete('/conversations/$id');
    if (state.conversationId == id) newChat();
  }

  void newChat() {
    _close();
    state = state.copyWith(
      messages: const [],
      conversationId: null,
      error: null,
    );
  }
}

final chatProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

double get seekStep => AppConfig.seekStep.toDouble();
