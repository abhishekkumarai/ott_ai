import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Refresh-token storage for native builds (Keystore / DPAPI).
/// On web nothing is stored: the refresh token is an HttpOnly cookie.
class TokenStore {
  // Pre-rename key (the app was called "Reel"); kept so existing sessions survive.
  static const _key = 'reel_refresh_token';
  final _storage = const FlutterSecureStorage();

  Future<String?> read() async => kIsWeb ? null : _storage.read(key: _key);

  Future<void> write(String token) async {
    if (!kIsWeb) await _storage.write(key: _key, value: token);
  }

  Future<void> clear() async {
    if (!kIsWeb) await _storage.delete(key: _key);
  }
}
