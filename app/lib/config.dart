import 'package:flutter/foundation.dart';

/// Where the nginx front (which also proxies /api) is reachable.
///
/// Web builds are served by that same origin. Native builds default to the Android
/// emulator's host alias or localhost, and can be pointed elsewhere with
/// `--dart-define=API_BASE=https://reel.example.com`.
class AppConfig {
  static const _override = String.fromEnvironment('API_BASE');

  static String get apiBase {
    if (_override.isNotEmpty) return _override;
    if (kIsWeb) return Uri.base.origin;
    if (defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:8088';
    return 'http://localhost:8088';
  }

  static String get playerUrl => '$apiBase/player/player.html';

  static const seekStep = 25;
}
