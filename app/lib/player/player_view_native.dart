import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../config.dart';
import 'player_handle.dart';

/// Android / Windows: a WebView (Android WebView / WebView2) hosting the same
/// player.html, driven through evaluateJavascript. Navigation is locked to the
/// player page; YouTube runs inside its own sub-frame.
class PlayerView extends StatefulWidget {
  const PlayerView({super.key, required this.handle});
  final PlayerHandle handle;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> implements PlayerTransport {
  InAppWebViewController? _controller;
  static const _commands = {
    'load',
    'seekBy',
    'seekTo',
    'pause',
    'play',
    'stop',
    'unmute',
    'mute',
    'setVolume',
    'setRate',
    'captions',
    'loop',
    'unloop',
  };
  static final _id = RegExp(
    r'^([A-Za-z0-9_-]{11}|vidy:(movie|tv|anime):[A-Za-z0-9_/-]+)$',
  );
  late final Uri _player = Uri.parse(AppConfig.playerUrl);

  @override
  void dispose() {
    widget.handle.detach(this);
    super.dispose();
  }

  @override
  void send(
    String cmd, {
    String? id,
    double? start,
    double? end,
    double? seconds,
    double? value,
  }) {
    if (!_commands.contains(cmd)) return;
    if (id != null && !_id.hasMatch(id)) return;
    // Only numbers and a validated id are ever interpolated into the script.
    final args = switch (cmd) {
      'load' => '${jsonEncode(id)}, ${jsonEncode(start ?? 0)}',
      'seekBy' || 'seekTo' => jsonEncode(seconds ?? 0),
      'setVolume' || 'setRate' => jsonEncode(value ?? 0),
      'captions' => (value ?? 0) == 1 ? 'true' : 'false',
      'loop' => '${jsonEncode(start ?? 0)}, ${jsonEncode(end ?? 0)}',
      _ => '',
    };
    _controller?.evaluateJavascript(
      source: 'window.ottPlayer && window.ottPlayer.$cmd($args);',
    );
  }

  bool _isPlayerPage(WebUri? url) =>
      url != null &&
      url.scheme == _player.scheme &&
      url.host == _player.host &&
      url.port == _player.port &&
      url.path == _player.path;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(AppConfig.playerUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          mediaPlaybackRequiresUserGesture: false,
          allowsInlineMediaPlayback: true,
          useShouldOverrideUrlLoading: true,
          supportZoom: false,
          disableContextMenu: true,
          transparentBackground: true,
          allowFileAccess: false,
          allowContentAccess: false,
          thirdPartyCookiesEnabled: false,
        ),
        onWebViewCreated: (c) {
          _controller = c;
          c.addJavaScriptHandler(
            handlerName: 'ott',
            callback: (args) {
              final data = args.isNotEmpty ? args.first : null;
              if (data is! Map || data['source'] != 'ott-player') return null;
              final event = PlayerEvent.fromMap(data);
              if (event.type == 'ready') widget.handle.attach(this);
              widget.handle.emit(event);
              return null;
            },
          );
        },
        shouldOverrideUrlLoading: (c, action) async {
          if (action.isForMainFrame == false) {
            return NavigationActionPolicy.ALLOW;
          }
          return _isPlayerPage(action.request.url)
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
        onPermissionRequest: (c, request) async => PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        ),
      ),
    );
  }
}
