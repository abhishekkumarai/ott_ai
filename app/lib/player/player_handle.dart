import 'dart:async';

/// Events coming back from player.js.
class PlayerEvent {
  const PlayerEvent(
    this.type, {
    this.t = 0,
    this.d = 0,
    this.playing = false,
    this.message,
    this.volume,
    this.muted,
    this.rate,
    this.quality,
    this.captions,
    this.loopA,
    this.loopB,
    this.hasLoop = false,
  });
  final String
  type; // ready | time | state | stopped | ended | end-reached | muted | error
  final double t;
  final double d;
  final bool playing;
  final String? message;

  /// Present on full state snapshots (time/state events); null otherwise.
  final double? volume;
  final bool? muted;
  final double? rate;
  final String? quality;
  final bool? captions;
  final double? loopA;
  final double? loopB;

  /// Whether the snapshot carried loop fields at all (so null means "no loop").
  final bool hasLoop;

  factory PlayerEvent.fromMap(Map map) {
    double n(Object? v) => v is num && v.isFinite ? v.toDouble() : 0;
    double? opt(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    final q = map['quality'];
    return PlayerEvent(
      map['type'] is String ? map['type'] as String : 'unknown',
      t: n(map['t']),
      d: n(map['d']),
      playing: map['playing'] == true,
      message: map['message'] is String ? (map['message'] as String) : null,
      volume: opt(map['volume']),
      muted: map['muted'] is bool ? map['muted'] as bool : null,
      rate: opt(map['rate']),
      quality: q is String && q.length <= 8 ? q : null,
      captions: map['captions'] is bool ? map['captions'] as bool : null,
      loopA: opt(map['loopA']),
      loopB: opt(map['loopB']),
      hasLoop: map.containsKey('loopA'),
    );
  }
}

/// Transport implemented by the platform-specific player view.
abstract class PlayerTransport {
  void send(
    String cmd, {
    String? id,
    double? start,
    double? end,
    double? seconds,
    double? value,
  });
}

/// Platform-neutral handle the rest of the app talks to. Commands issued before the
/// view is attached are queued (only the latest load matters).
class PlayerHandle {
  final _events = StreamController<PlayerEvent>.broadcast();
  PlayerTransport? _transport;
  final List<void Function(PlayerTransport)> _queue = [];

  static final _id = RegExp(
    r'^([A-Za-z0-9_-]{11}|[a-z0-9_-]+:(movie|tv|anime|video):[A-Za-z0-9_/-]+)$',
  );

  Stream<PlayerEvent> get events => _events.stream;

  void attach(PlayerTransport t) {
    _transport = t;
    for (final f in _queue) {
      f(t);
    }
    _queue.clear();
  }

  void detach(PlayerTransport t) {
    if (identical(_transport, t)) _transport = null;
  }

  void emit(PlayerEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _run(void Function(PlayerTransport) f) {
    final t = _transport;
    if (t != null) {
      f(t);
    } else {
      _queue.add(f);
    }
  }

  void load(String id, {double start = 0}) {
    if (!_id.hasMatch(id)) return;
    _queue.clear();
    _run((t) => t.send('load', id: id, start: start));
  }

  void seekBy(double seconds) {
    if (seconds.isFinite) _run((t) => t.send('seekBy', seconds: seconds));
  }

  /// Jump to an absolute position (chapters, scrubbing).
  void seekTo(double seconds) {
    if (seconds.isFinite) _run((t) => t.send('seekTo', seconds: seconds));
  }

  void pause() => _run((t) => t.send('pause'));
  void play() => _run((t) => t.send('play'));
  void stop() => _transport?.send('stop');
  void unmute() => _run((t) => t.send('unmute'));
  void mute() => _run((t) => t.send('mute'));

  /// 0–100.
  void setVolume(double v) => _run((t) => t.send('setVolume', value: v));
  void setRate(double r) => _run((t) => t.send('setRate', value: r));
  void captions(bool on) => _run((t) => t.send('captions', value: on ? 1 : 0));

  /// Repeat [start]..[end] seconds until [unloop] (or a new video / stop).
  void loop(double start, double end) {
    if (start.isFinite && end.isFinite && end > start) {
      _run((t) => t.send('loop', start: start, end: end));
    }
  }

  void unloop() => _run((t) => t.send('unloop'));

  /// Web only: the page puts the player iframe in fullscreen (must run from a
  /// user gesture, so it is never queued).
  void fullscreen() => _transport?.send('fullscreen');

  void dispose() => _events.close();
}
