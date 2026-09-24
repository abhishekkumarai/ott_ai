import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api.dart';

final apiProvider = Provider<ApiClient>((ref) => ApiClient());

class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    required this.isAdmin,
    this.isDemo = false,
  });
  final String id;
  final String email;
  final bool isAdmin;
  final bool isDemo;

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
    id: j['id'] as String,
    email: j['email'] as String,
    isAdmin: j['is_admin'] as bool,
    isDemo: j['is_demo'] as bool? ?? false,
  );
}

enum AuthStatus { unknown, signedOut, signedIn }

class AuthState {
  const AuthState(this.status, [this.user]);
  final AuthStatus status;
  final AppUser? user;
}

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    final api = ref.read(apiProvider);
    api.onSessionExpired = () => state = const AuthState(AuthStatus.signedOut);
    Future.microtask(_restore);
    return const AuthState(AuthStatus.unknown);
  }

  Future<void> _restore() async {
    final data = await ref.read(apiProvider).refresh();
    // A sign-in (or demo) that finished first wins; don't overwrite it.
    if (state.status != AuthStatus.unknown) return;
    state = data == null
        ? const AuthState(AuthStatus.signedOut)
        : AuthState(
            AuthStatus.signedIn,
            AppUser.fromJson(data['user'] as Map<String, dynamic>),
          );
  }

  Future<void> signIn(
    String email,
    String password, {
    required bool register,
  }) async {
    final data = await ref
        .read(apiProvider)
        .login(email, password, register: register);
    state = AuthState(
      AuthStatus.signedIn,
      AppUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  /// Throwaway session so people can try everything without an account.
  Future<void> startDemo() async {
    final data = await ref.read(apiProvider).demo();
    state = AuthState(
      AuthStatus.signedIn,
      AppUser.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  Future<void> signOut() async {
    await ref.read(apiProvider).logout();
    state = const AuthState(AuthStatus.signedOut);
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
