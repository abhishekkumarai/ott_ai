import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../api/api.dart';
import '../widgets/logo.dart';
import 'auth.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    String? problem;
    if (!_emailRe.hasMatch(email)) {
      problem = 'Enter a valid email address.';
    } else if (_register && password.length < 10) {
      problem = 'Use at least 10 characters for your password.';
    } else if (password.isEmpty) {
      problem = 'Enter your password.';
    }
    if (problem != null) return setState(() => _error = problem);

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authProvider.notifier)
          .signIn(email, password, register: _register);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _demo() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).startDemo();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      backgroundColor: cs.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: Logo(size: 20)),
                    const SizedBox(height: 32),
                    Text(
                      _register ? 'Create an account' : 'Welcome back',
                      style: theme.textTheme.h3,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _register
                          ? 'Your chats and watch history stay with your account.'
                          : 'Sign in to pick up where you left off.',
                      style: theme.textTheme.muted,
                    ),
                    const SizedBox(height: 24),
                    Text('Email', style: theme.textTheme.small),
                    const SizedBox(height: 6),
                    ShadInput(
                      controller: _email,
                      placeholder: const Text('you@example.com'),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      maxLength: 254,
                    ),
                    const SizedBox(height: 16),
                    Text('Password', style: theme.textTheme.small),
                    const SizedBox(height: 6),
                    ShadInput(
                      controller: _password,
                      obscureText: true,
                      autofillHints: [
                        _register
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      onSubmitted: (_) => _submit(),
                      maxLength: 128,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: theme.textTheme.small.copyWith(
                          color: cs.destructive,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    ShadButton(
                      onPressed: _busy ? null : _submit,
                      leading: _busy
                          ? SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: cs.primaryForeground,
                              ),
                            )
                          : null,
                      child: Text(_register ? 'Create account' : 'Sign in'),
                    ),
                    const SizedBox(height: 12),
                    ShadButton.ghost(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _register = !_register;
                              _error = null;
                            }),
                      child: Text(
                        _register ? 'Sign in instead' : 'Create an account',
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(child: Divider(color: cs.border, height: 1)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'or',
                            style: theme.textTheme.muted.copyWith(fontSize: 12),
                          ),
                        ),
                        Expanded(child: Divider(color: cs.border, height: 1)),
                      ],
                    ),
                    const SizedBox(height: 20),
                    ShadButton.outline(
                      onPressed: _busy ? null : _demo,
                      leading: const Icon(LucideIcons.play, size: 16),
                      child: const Text('Try the demo'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No sign-up. A temporary session that is deleted after 24 hours.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.muted.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
