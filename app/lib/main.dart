import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'auth/auth.dart';
import 'auth/demo_screen.dart';
import 'auth/login_screen.dart';
import 'chat/chat_screen.dart';
import 'settings/preferences.dart';
import 'settings/settings_screen.dart';
import 'theme.dart';

void main() {
  runApp(const ProviderScope(child: OttAiApp()));
}

/// Bridges auth state changes into go_router's refreshListenable.
class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Ref ref) {
    ref.listen(authProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthListenable(ref);
  return GoRouter(
    initialLocation: '/',
    refreshListenable: listenable,
    redirect: (context, state) {
      final status = ref.read(authProvider).status;
      final loc = state.matchedLocation;
      final atLogin = loc == '/login';
      // /demo is the landing page's "Try the demo" link: it starts a demo session
      // unless the visitor is already signed in.
      if (loc == '/demo') return status == AuthStatus.signedIn ? '/' : null;
      return switch (status) {
        AuthStatus.unknown => atLogin ? null : '/splash',
        AuthStatus.signedOut => atLogin ? null : '/login',
        AuthStatus.signedIn => (atLogin || loc == '/splash') ? '/' : null,
      };
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const ChatScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/splash', builder: (_, _) => const _Splash()),
      GoRoute(path: '/demo', builder: (_, _) => const DemoScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    ],
  );
});

class OttAiApp extends ConsumerWidget {
  const OttAiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadApp.router(
      title: 'OTT-AI',
      theme: lightTheme(),
      darkTheme: darkTheme(),
      // Light by default; Settings › Appearance can pick dark or follow the system.
      themeMode: ref.watch(preferencesProvider.select((p) => p.appearance)),
      routerConfig: ref.watch(routerProvider),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ColoredBox(
      color: theme.colorScheme.background,
      child: Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.mutedForeground,
          ),
        ),
      ),
    );
  }
}
