import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../api/api.dart';
import '../widgets/logo.dart';
import 'auth.dart';

/// Target of the landing page's "Try the demo" link (/app/#/demo).
/// Waits for the stored-session check, then starts a demo session if needed.
/// The router moves on to the chat as soon as the user is signed in.
class DemoScreen extends ConsumerStatefulWidget {
  const DemoScreen({super.key});

  @override
  ConsumerState<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends ConsumerState<DemoScreen> {
  bool _started = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeStart(ref.read(authProvider).status),
    );
  }

  Future<void> _maybeStart(AuthStatus status) async {
    if (_started || status != AuthStatus.signedOut) return;
    _started = true;
    try {
      await ref.read(authProvider.notifier).startDemo();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      authProvider.select((s) => s.status),
      (_, status) => _maybeStart(status),
    );
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      backgroundColor: cs.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Logo(size: 20),
              const SizedBox(height: 24),
              if (_error == null) ...[
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.mutedForeground,
                  ),
                ),
                const SizedBox(height: 12),
                Text('Starting your demo…', style: theme.textTheme.muted),
              ] else ...[
                Text(
                  _error!,
                  style: theme.textTheme.small.copyWith(color: cs.destructive),
                ),
                const SizedBox(height: 16),
                ShadButton.outline(
                  onPressed: () => context.go('/login'),
                  child: const Text('Back to sign in'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
