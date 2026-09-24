import 'dart:async';

/// Events coming back from player.js.
class PlayerEvent {
  const PlayerEvent(
    this.type, {
    this.t = 0,
    this.d = 0,
    this.playing = false,
    this.message,
  });
  final String
  type; // ready | time | state | stopped | ended | end-reached | muted | error
  final double t;
  final double d;
  final bool playing;
  final String? message;

  factory PlayerEvent.fromMap(Map map) {
    double n(Object? v) => v is num && v.isFinite ? v.toDouble() : 0;
    return PlayerEvent(
      map['type'] is String ? map['type'] as String : 'unknown',
      t: n(map['t']),
      d: n(map['d']),
      playing: map['playing'] == true,
      message: map['message'] is String ? (map['message'] as String) : null,
    );
  }
}

/// Transport implemented by the platform-specific player view.
abstract class PlayerTransport {
  void send(String cmd, {String? id, double? start, double? seconds});
}

/// Platform-neutral handle the rest of the app talks to. Commands issued before the
/// view is attached are queued (only the latest load matters).
class PlayerHandle {
  final _events = StreamController<PlayerEvent>.broadcast();
  PlayerTransport? _transport;
  final List<void Function(PlayerTransport)> _queue = [];

  static final _id = RegExp(r'^[A-Za-z0-9_-]{11}$');

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

  void pause() => _run((t) => t.send('pause'));
  void play() => _run((t) => t.send('play'));
  void stop() => _transport?.send('stop');
  void unmute() => _run((t) => t.send('unmute'));

  void dispose() => _events.close();
}
