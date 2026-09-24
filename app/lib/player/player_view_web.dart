import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../config.dart';
import 'player_handle.dart';

/// Web: a same-origin iframe hosting player.html, driven with postMessage.
class PlayerView extends StatefulWidget {
  const PlayerView({super.key, required this.handle});
  final PlayerHandle handle;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> implements PlayerTransport {
  web.HTMLIFrameElement? _iframe;
  late final JSFunction _listener = _onMessage.toJS;
  late final JSFunction _blurListener = _onWindowBlur.toJS;
  final String _origin = web.window.location.origin;

  @override
  void initState() {
    super.initState();
    web.window.addEventListener('message', _listener);
    web.window.addEventListener('blur', _blurListener);
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', _listener);
    web.window.removeEventListener('blur', _blurListener);
    widget.handle.detach(this);
    super.dispose();
  }

  void _onMessage(web.MessageEvent e) {
    final frame = _iframe?.contentWindow;
    if (e.origin != _origin || frame == null || e.source == null) return;
    if (!e.source!.strictEquals(frame).toDart) return;
    final data = e.data.dartify();
    if (data is! Map || data['source'] != 'ott-player') return;
    final event = PlayerEvent.fromMap(data);
    if (event.type == 'ready') widget.handle.attach(this);
    widget.handle.emit(event);
  }

  /// Clicking the video moves browser focus into the YouTube iframe, which would
  /// swallow everything typed afterwards. Hand focus straight back to the app.
  void _onWindowBlur(web.Event _) {
    Future.delayed(const Duration(milliseconds: 60), () {
      final active = web.document.activeElement;
      if (!mounted || active == null || _iframe == null) return;
      if (active.strictEquals(_iframe).toDart) {
        web.window.focus();
        widget.handle.emit(const PlayerEvent('refocus'));
      }
    });
  }

  @override
  void send(String cmd, {String? id, double? start, double? seconds}) {
    final msg = <String, Object?>{
      'target': 'ott-player',
      'cmd': cmd,
      'id': ?id,
      'start': ?start,
      'seconds': ?seconds,
    };
    _iframe?.contentWindow?.postMessage(msg.jsify(), _origin.toJS);
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView.fromTagName(
      tagName: 'iframe',
      onElementCreated: (element) {
        final f = element as web.HTMLIFrameElement;
        f.src = AppConfig.playerUrl;
        f.allow = 'autoplay; encrypted-media; fullscreen; picture-in-picture';
        f.allowFullscreen = true;
        f.referrerPolicy = 'strict-origin-when-cross-origin';
        f.title = 'Video player';
        f.style
          ..border = '0'
          ..width = '100%'
          ..height = '100%'
          ..backgroundColor = '#000';
        _iframe = f;
      },
    );
  }
}
