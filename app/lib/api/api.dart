import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/token_store.dart';
import '../config.dart';

class ApiException implements Exception {
  ApiException(this.message, [this.status]);
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// Dio wrapper: attaches the in-memory access token and transparently refreshes it
/// once on 401. On web the refresh token is an HttpOnly cookie; on native it is kept
/// in secure storage and sent in the body.
class ApiClient {
  ApiClient({TokenStore? store}) : _store = store ?? TokenStore() {
    _dio = Dio(BaseOptions(
      baseUrl: '${AppConfig.apiBase}/api',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      contentType: Headers.jsonContentType,
      headers: {if (!kIsWeb) 'X-Client': 'native'},
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (accessToken != null) options.headers['Authorization'] = 'Bearer $accessToken';
        handler.next(options);
      },
      onError: (err, handler) async {
        final req = err.requestOptions;
        final canRetry = err.response?.statusCode == 401 &&
            !req.path.startsWith('/auth/') &&
            req.extra['retried'] != true;
        if (canRetry && await refresh() != null) {
          req.extra['retried'] = true;
          req.headers['Authorization'] = 'Bearer $accessToken';
          try {
            return handler.resolve(await _dio.fetch(req));
          } on DioException catch (e) {
            return handler.next(e);
          }
        }
        if (err.response?.statusCode == 401) onSessionExpired?.call();
        handler.next(err);
      },
    ));
  }

  late final Dio _dio;
  final TokenStore _store;
  String? accessToken;
  VoidCallback? onSessionExpired;
  Future<Map<String, dynamic>?>? _refreshing;

  Future<Map<String, dynamic>> _session(Map<String, dynamic> data) async {
    accessToken = data['access_token'] as String?;
    final rt = data['refresh_token'] as String?;
    if (rt != null) await _store.write(rt);
    return data;
  }

  /// Returns the session payload, or null when there is no valid session.
  /// Concurrent callers share one in-flight refresh (tokens rotate on every use).
  Future<Map<String, dynamic>?> refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<Map<String, dynamic>?> _doRefresh() async {
    final stored = kIsWeb ? null : await _store.read();
    if (!kIsWeb && stored == null) return null;
    try {
      final r = await _dio.post('/auth/refresh', data: {'refresh_token': ?stored});
      return _session(Map<String, dynamic>.from(r.data as Map));
    } on DioException {
      accessToken = null;
      await _store.clear();
      return null;
    }
  }

  Future<Map<String, dynamic>> login(String email, String password, {bool register = false}) async {
    final data = await post(register ? '/auth/register' : '/auth/login',
        {'email': email, 'password': password});
    return _session(data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> demo() async {
    final data = await post('/auth/demo');
    return _session(data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    final stored = kIsWeb ? null : await _store.read();
    try {
      await _dio.post('/auth/logout', data: {'refresh_token': ?stored});
    } on DioException {
      // best effort
    }
    accessToken = null;
    await _store.clear();
  }

  Future<dynamic> get(String path, [Map<String, dynamic>? query]) =>
      _wrap(() => _dio.get(path, queryParameters: query));

  Future<dynamic> post(String path, [Object? body]) => _wrap(() => _dio.post(path, data: body));

  Future<dynamic> delete(String path) => _wrap(() => _dio.delete(path));

  Future<dynamic> _wrap(Future<Response> Function() call) async {
    try {
      final r = await call();
      return r.data;
    } on DioException catch (e) {
      throw ApiException(_message(e), e.response?.statusCode);
    }
  }

  static String _message(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['detail'] is String) return data['detail'] as String;
    if (data is Map && data['detail'] is List) {
      final first = (data['detail'] as List).firstOrNull;
      if (first is Map && first['msg'] is String) {
        return (first['msg'] as String).replaceFirst('Value error, ', '');
      }
    }
    return switch (e.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout =>
        'Can’t reach the server. Check your connection.',
      DioExceptionType.receiveTimeout => 'The server took too long to answer.',
      _ => 'Something went wrong (${e.response?.statusCode ?? 'network'}).',
    };
  }
}
