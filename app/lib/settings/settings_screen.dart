import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../api/api.dart';
import '../auth/auth.dart';
import '../chat/chat_controller.dart';
import '../shell/history.dart';
import '../shell/shortcuts.dart';
import '../theme.dart';
import 'preferences.dart';

/// Settings (OTTAI-14). Every change saves immediately to `/api/me/preferences`.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < mobileBreakpoint;
    return Scaffold(
      backgroundColor: cs.background,
      body: SafeArea(
        child: Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: cs.border)),
              ),
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    ShadButton.ghost(
                      leading: const Icon(LucideIcons.arrowLeft, size: 16),
                      onPressed: () => context.go('/'),
                      child: const Text('Back to chat'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: narrow ? 12 : 24,
                  vertical: 24,
                ),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Heading(),
                          _ModelSection(),
                          _PlayerSection(),
                          _PlaybackSection(),
                          _VoiceSection(),
                          _AppearanceSection(),
                          _ShortcutsSection(),
                          _AccountSection(),
                          _HistorySection(),
                          SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Settings',
            style: theme.textTheme.h2.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Saved to your account and applied right away.',
            style: theme.textTheme.muted,
          ),
        ],
      ),
    );
  }
}

/// A titled card section.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.description,
  });
  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: ShadCard(
      radius: BorderRadius.circular(16),
      padding: const EdgeInsets.all(20),
      title: Text(title),
      description: description == null ? null : Text(description!),
      child: Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// Label on the left, control on the right (stacks on narrow screens).
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.control, this.sublabel});
  final String label;
  final String? sublabel;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
        ),
        if (sublabel != null)
          Text(sublabel!, style: theme.textTheme.muted.copyWith(fontSize: 13)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 420
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [text, const SizedBox(height: 8), control],
              )
            : Row(
                children: [
                  Expanded(child: text),
                  const SizedBox(width: 16),
                  control,
                ],
              ),
      ),
    );
  }
}

Future<void> _save(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> patch,
) async {
  try {
    await ref.read(preferencesProvider.notifier).update(patch);
  } on ApiException catch (e) {
    if (context.mounted) {
      ShadToaster.of(
        context,
      ).show(ShadToast.destructive(description: Text(e.message)));
    }
  }
}

class _ModelSection extends ConsumerWidget {
  const _ModelSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = [
      for (final m in ref.watch(chatProvider.select((s) => s.models))) m.name,
    ];
    // The default for new chats; a chat can switch its own model in the chat box.
    final saved = ref.watch(preferencesProvider.select((p) => p.model));
    final fallback = ref.watch(
      chatProvider.select((s) => s.defaultModel ?? s.model),
    );
    final model = models.contains(saved) ? saved : fallback;
    return _Section(
      title: 'AI model',
      description:
          'Runs locally with Ollama. Smaller models answer faster. This is the '
          'default for new chats; switch a chat’s model under its message box.',
      children: [
        if (models.isEmpty)
          Text(
            'The AI server is offline; search still works with keywords.',
            style: ShadTheme.of(context).textTheme.muted,
          )
        else
          _Row(
            label: 'Model',
            control: ShadSelect<String>(
              key: ValueKey(model),
              initialValue: model,
              minWidth: 220,
              options: [
                for (final m in models) ShadOption(value: m, child: Text(m)),
              ],
              selectedOptionBuilder: (_, v) => Text(v),
              onChanged: (m) {
                if (m == null) return;
                ref.read(chatProvider.notifier).setModel(m);
                _save(context, ref, {'model': m});
              },
            ),
          ),
        const _OllamaHealthCheck(),
      ],
    );
  }
}

class OllamaHealthData {
  const OllamaHealthData({
    required this.status,
    required this.ok,
    this.version,
    this.models = const [],
    this.availableModels = const [],
    this.installedCount = 0,
    this.embedModel = '',
    this.embedAvailable = false,
    this.ollamaUrl = '',
    this.latencyMs,
    required this.message,
  });

  final String status;
  final bool ok;
  final String? version;
  final List<String> models;
  final List<String> availableModels;
  final int installedCount;
  final String embedModel;
  final bool embedAvailable;
  final String ollamaUrl;
  final int? latencyMs;
  final String message;

  factory OllamaHealthData.fromJson(Map<String, dynamic> j) => OllamaHealthData(
    status: j['status'] as String? ?? (j['ok'] == true ? 'healthy' : 'unreachable'),
    ok: j['ok'] == true,
    version: j['version'] as String?,
    models: [for (final m in (j['models'] as List? ?? const [])) m.toString()],
    availableModels: [
      for (final m in (j['available_models'] as List? ?? const [])) m.toString()
    ],
    installedCount: (j['installed_count'] as num?)?.toInt() ?? 0,
    embedModel: j['embed_model'] as String? ?? '',
    embedAvailable: j['embed_available'] == true,
    ollamaUrl: j['ollama_url'] as String? ?? '',
    latencyMs: (j['latency_ms'] as num?)?.toInt(),
    message: j['message'] as String? ?? '',
  );
}

class _OllamaHealthCheck extends ConsumerStatefulWidget {
  const _OllamaHealthCheck();

  @override
  ConsumerState<_OllamaHealthCheck> createState() => _OllamaHealthCheckState();
}

class _OllamaHealthCheckState extends ConsumerState<_OllamaHealthCheck> {
  bool _loading = false;
  OllamaHealthData? _health;

  Future<void> _checkHealth() async {
    if (_loading) return;
    setState(() => _loading = true);

    try {
      final res = await ref.read(apiProvider).get('/ollama/health');
      if (!mounted) return;
      final data = OllamaHealthData.fromJson(Map<String, dynamic>.from(res as Map));
      setState(() {
        _health = data;
        _loading = false;
      });

      if (data.ok) {
        await ref.read(chatProvider.notifier).loadModels();
      }

      if (mounted) {
        if (data.status == 'healthy') {
          ShadToaster.of(context).show(
            ShadToast(
              title: const Text('Ollama is healthy'),
              description: Text(data.message),
            ),
          );
        } else if (data.status == 'degraded') {
          ShadToaster.of(context).show(
            ShadToast(
              title: const Text('Ollama warning'),
              description: Text(data.message),
            ),
          );
        } else {
          ShadToaster.of(context).show(
            ShadToast.destructive(
              title: const Text('Ollama unreachable'),
              description: Text(data.message),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      final fallback = OllamaHealthData(
        status: 'unreachable',
        ok: false,
        message: 'Failed to connect: $e',
      );
      setState(() {
        _health = fallback;
        _loading = false;
      });
      ShadToaster.of(context).show(
        ShadToast.destructive(
          title: const Text('Health check failed'),
          description: Text(fallback.message),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final h = _health;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row(
            label: 'Ollama health',
            sublabel: 'Check connectivity to the local Ollama instance.',
            control: ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: _loading ? null : _checkHealth,
              leading: _loading
                  ? SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.foreground,
                      ),
                    )
                  : const Icon(LucideIcons.activity, size: 14),
              child: Text(_loading
                  ? 'Checking…'
                  : (h == null ? 'Check health' : 'Re-check')),
            ),
          ),
          if (h != null) ...[
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: cs.muted.withValues(alpha: 0.35),
                border: Border.all(
                  color: _healthColor(context, h.status).withValues(alpha: 0.4),
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _HealthBadge(health: h),
                        const SizedBox(width: 8),
                        if (h.version != null)
                          Text(
                            'v${h.version}',
                            style: mono(context, size: 11, color: cs.mutedForeground),
                          ),
                        const Spacer(),
                        if (h.ollamaUrl.isNotEmpty)
                          Text(
                            h.ollamaUrl,
                            style: mono(context, size: 10, color: cs.mutedForeground),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      h.message,
                      style: theme.textTheme.small.copyWith(
                        color: cs.foreground,
                        fontSize: 12,
                      ),
                    ),
                    if (h.models.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Installed models (${h.installedCount}):',
                        style: theme.textTheme.muted.copyWith(fontSize: 11),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final m in h.models)
                            ShadBadge.outline(
                              child: Text(
                                m,
                                style: mono(context, size: 10),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Color _healthColor(BuildContext context, String status) => switch (status) {
  'healthy' => success,
  'degraded' => warning,
  _ => ShadTheme.of(context).colorScheme.destructive,
};

class _HealthBadge extends StatelessWidget {
  const _HealthBadge({required this.health});

  final OllamaHealthData health;

  @override
  Widget build(BuildContext context) {
    final color = _healthColor(context, health.status);
    final (icon, label) = switch (health.status) {
      'healthy' => (
        LucideIcons.checkCircle2,
        health.latencyMs != null ? 'Healthy • ${health.latencyMs}ms' : 'Healthy',
      ),
      'degraded' => (LucideIcons.alertTriangle, 'Degraded'),
      _ => (LucideIcons.xCircle, 'Offline / Unreachable'),
    };
    return ShadBadge.raw(
      variant: ShadBadgeVariant.primary,
      backgroundColor: color.withValues(alpha: 0.14),
      foregroundColor: color,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: mono(context, size: 11, color: color)),
        ],
      ),
    );
  }
}

class _PlayerSection extends ConsumerWidget {
  const _PlayerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(preferencesProvider.select((p) => p.playerMode));
    return _Section(
      title: 'Player',
      description:
          'Where new videos open. You can switch any time with I and T.',
      children: [
        ShadRadioGroup<PlayerMode>(
          key: ValueKey(mode),
          initialValue: mode,
          onChanged: (m) {
            if (m == null) return;
            ref.read(playerModeProvider.notifier).set(m);
            _save(context, ref, {'player_mode': m.name});
          },
          items: const [
            ShadRadio(
              value: PlayerMode.mini,
              label: Text('Mini player'),
              sublabel: Text(
                'The chat stays in front; the video floats in a corner.',
              ),
            ),
            ShadRadio(
              value: PlayerMode.theater,
              label: Text('Theater mode'),
              sublabel: Text(
                'A large player with the latest messages underneath.',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PlaybackSection extends ConsumerWidget {
  const _PlaybackSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(preferencesProvider);
    return _Section(
      title: 'Playback',
      children: [
        _Row(
          label: 'Autoplay next video',
          sublabel: 'When a video ends, play the top unwatched recommendation.',
          control: ShadSwitch(
            value: p.autoplayNext,
            onChanged: (v) => _save(context, ref, {'autoplay_next': v}),
          ),
        ),
        _Row(
          label: 'Default speed',
          control: ShadSelect<double>(
            key: ValueKey(p.playbackRate),
            initialValue: p.playbackRate,
            minWidth: 120,
            options: [
              for (final r in playbackRates)
                ShadOption(value: r, child: Text(_rate(r))),
            ],
            selectedOptionBuilder: (_, v) => Text(_rate(v)),
            onChanged: (v) {
              if (v != null) _save(context, ref, {'playback_rate': v});
            },
          ),
        ),
        _Row(
          label: 'Start muted',
          sublabel: 'Videos begin without sound; press M to unmute.',
          control: ShadSwitch(
            value: p.startMuted,
            onChanged: (v) => _save(context, ref, {'start_muted': v}),
          ),
        ),
      ],
    );
  }

  static String _rate(double r) => r == 1 ? 'Normal' : '${r}x';
}

class _VoiceSection extends ConsumerWidget {
  const _VoiceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(preferencesProvider);
    return _Section(
      title: 'Voice',
      children: [
        _Row(
          label: 'Voice input',
          sublabel: 'Show the microphone in the message box.',
          control: ShadSwitch(
            value: p.voiceEnabled,
            onChanged: (v) => _save(context, ref, {'voice_enabled': v}),
          ),
        ),
        _Row(
          label: 'Language',
          control: ShadSelect<String>(
            key: ValueKey(p.voiceLanguage),
            initialValue: voiceLanguages.containsKey(p.voiceLanguage)
                ? p.voiceLanguage
                : 'en-US',
            minWidth: 180,
            enabled: p.voiceEnabled,
            options: [
              for (final e in voiceLanguages.entries)
                ShadOption(value: e.key, child: Text(e.value)),
            ],
            selectedOptionBuilder: (_, v) => Text(voiceLanguages[v] ?? v),
            onChanged: (v) {
              if (v != null) _save(context, ref, {'voice_language': v});
            },
          ),
        ),
      ],
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(preferencesProvider.select((p) => p.appearance));
    return _Section(
      title: 'Appearance',
      children: [
        ShadRadioGroup<ThemeMode>(
          key: ValueKey(a),
          initialValue: a,
          axis: Axis.horizontal,
          spacing: 20,
          onChanged: (m) {
            if (m != null) {
              _save(context, ref, {
                'appearance': Preferences.appearanceName(m),
              });
            }
          },
          items: const [
            ShadRadio(value: ThemeMode.light, label: Text('Light')),
            ShadRadio(value: ThemeMode.dark, label: Text('Dark')),
            ShadRadio(value: ThemeMode.system, label: Text('Match system')),
          ],
        ),
      ],
    );
  }
}

class _ShortcutsSection extends StatelessWidget {
  const _ShortcutsSection();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return _Section(
      title: 'Keyboard shortcuts',
      description: 'Player keys work when you’re not typing in a text box.',
      children: [
        for (final (keys, action) in shortcutList())
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(child: Text(action, style: theme.textTheme.small)),
                ShadBadge.outline(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 1,
                  ),
                  child: Text(keys, style: mono(context, size: 12)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider.select((a) => a.user));
    if (user == null) return const SizedBox.shrink();
    void signOut() {
      ref.read(chatProvider.notifier).newChat();
      ref.read(authProvider.notifier).signOut();
    }

    return _Section(
      title: 'Account',
      children: [
        _Row(
          label: user.isDemo ? 'Demo session' : user.email,
          sublabel: user.isDemo
              ? 'Deleted with its chats 24 hours after it started.'
              : 'Signed in',
          control: ShadButton.outline(
            size: ShadButtonSize.sm,
            leading: const Icon(LucideIcons.logOut, size: 14),
            onPressed: signOut,
            child: const Text('Sign out'),
          ),
        ),
        if (!user.isDemo) ...[
          const _ChangePassword(),
          _Row(
            label: 'Delete account',
            sublabel:
                'Permanently removes your account, chats and watch history.',
            control: ShadButton.destructive(
              size: ShadButtonSize.sm,
              onPressed: () => _confirmDelete(context, ref, user.email),
              child: const Text('Delete account'),
            ),
          ),
        ],
      ],
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, String email) {
    showShadDialog(
      context: context,
      builder: (ctx) => _DeleteAccountDialog(email: email),
    );
  }
}

class _ChangePassword extends ConsumerStatefulWidget {
  const _ChangePassword();

  @override
  ConsumerState<_ChangePassword> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends ConsumerState<_ChangePassword> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_next.text.length < 10) {
      setState(() => _error = 'Use at least 10 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authProvider.notifier)
          .changePassword(_current.text, _next.text);
      _current.clear();
      _next.clear();
      if (mounted) {
        ShadToaster.of(context).show(
          const ShadToast(
            description: Text(
              'Password changed. Other devices were signed out.',
            ),
          ),
        );
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Change password',
            style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            'Signs out your other devices.',
            style: theme.textTheme.muted.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 10),
          ShadInput(
            controller: _current,
            obscureText: true,
            placeholder: const Text('Current password'),
            autofillHints: const [AutofillHints.password],
          ),
          const SizedBox(height: 8),
          ShadInput(
            controller: _next,
            obscureText: true,
            placeholder: const Text('New password (10+ characters)'),
            autofillHints: const [AutofillHints.newPassword],
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _error!,
                style: theme.textTheme.small.copyWith(
                  color: theme.colorScheme.destructive,
                ),
              ),
            ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: ShadButton(
              size: ShadButtonSize.sm,
              onPressed: _busy ? null : _submit,
              child: const Text('Update password'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Deleting needs the email typed back and the password (no single-click delete).
class _DeleteAccountDialog extends ConsumerStatefulWidget {
  const _DeleteAccountDialog({required this.email});
  final String email;

  @override
  ConsumerState<_DeleteAccountDialog> createState() =>
      _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<_DeleteAccountDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _ready =>
      _email.text.trim().toLowerCase() == widget.email.toLowerCase() &&
      _password.text.isNotEmpty;

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final chat = ref.read(chatProvider.notifier);
    try {
      await ref.read(authProvider.notifier).deleteAccount(_password.text);
      chat.newChat();
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadDialog.alert(
      title: const Text('Delete your account?'),
      description: Text(
        'This permanently deletes ${widget.email}, all chats and watch history. '
        'It can’t be undone.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          onPressed: _ready && !_busy ? _delete : null,
          child: const Text('Delete account'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ShadInput(
              controller: _email,
              placeholder: Text('Type ${widget.email} to confirm'),
            ),
            const SizedBox(height: 8),
            ShadInput(
              controller: _password,
              obscureText: true,
              placeholder: const Text('Password'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.destructive,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HistorySection extends ConsumerWidget {
  const _HistorySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _Section(
    title: 'History',
    children: [
      _Row(
        label: 'Clear all conversations',
        sublabel: 'Deletes every chat in your history.',
        control: ShadButton.outline(
          size: ShadButtonSize.sm,
          foregroundColor: ShadTheme.of(context).colorScheme.destructive,
          onPressed: () => showShadDialog(
            context: context,
            builder: (ctx) => ShadDialog.alert(
              title: const Text('Clear all conversations?'),
              description: const Text(
                'Every chat will be deleted. This can’t be undone.',
              ),
              actions: [
                ShadButton.outline(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                ShadButton.destructive(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    try {
                      await ref
                          .read(chatProvider.notifier)
                          .deleteAllConversations();
                      ref.invalidate(historyProvider);
                      if (context.mounted) {
                        ShadToaster.of(context).show(
                          const ShadToast(
                            description: Text('History cleared.'),
                          ),
                        );
                      }
                    } on ApiException catch (e) {
                      if (context.mounted) {
                        ShadToaster.of(context).show(
                          ShadToast.destructive(description: Text(e.message)),
                        );
                      }
                    }
                  },
                  child: const Text('Clear history'),
                ),
              ],
            ),
          ),
          child: const Text('Clear history'),
        ),
      ),
    ],
  );
}
