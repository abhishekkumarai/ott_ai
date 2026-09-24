import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../auth/auth.dart';
import '../chat/chat_controller.dart';
import '../theme.dart';
import '../widgets/logo.dart';

/// Left navigation. [expanded] shows labels (wide screens and the phone menu sheet);
/// otherwise it is a compact icon rail. [onHistory] is set when the history panel is
/// not permanently visible, adding a "History" entry that opens it.
class SideNav extends ConsumerWidget {
  const SideNav({
    super.key,
    required this.expanded,
    this.onHistory,
    this.onNavigate,
  });
  final bool expanded;
  final VoidCallback? onHistory;

  /// Called after an action (used to close the phone menu sheet).
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final chat = ref.read(chatProvider.notifier);
    final user = ref.watch(authProvider.select((a) => a.user));
    final models = ref.watch(chatProvider.select((s) => s.models));
    final model = ref.watch(chatProvider.select((s) => s.model));

    void run(VoidCallback f) {
      f();
      onNavigate?.call();
    }

    Widget item(
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool primary = false,
    }) {
      if (!expanded) {
        return ShadTooltip(
          builder: (_) => Text(label),
          child: primary
              ? ShadIconButton(icon: Icon(icon, size: 18), onPressed: onTap)
              : ShadIconButton.ghost(
                  icon: Icon(icon, size: 18),
                  onPressed: onTap,
                ),
        );
      }
      final child = Text(label);
      final leading = Icon(icon, size: 16);
      return SizedBox(
        width: double.infinity,
        child: primary
            ? ShadButton(
                onPressed: onTap,
                leading: leading,
                mainAxisAlignment: MainAxisAlignment.start,
                child: child,
              )
            : ShadButton.ghost(
                onPressed: onTap,
                leading: leading,
                mainAxisAlignment: MainAxisAlignment.start,
                child: child,
              ),
      );
    }

    final account = user == null
        ? const SizedBox.shrink()
        : expanded
        ? Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: cs.muted,
                child: Icon(
                  LucideIcons.circleUser,
                  size: 16,
                  color: cs.mutedForeground,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.isDemo ? 'Demo session' : user.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.small.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (user.isDemo)
                      Text(
                        'Deleted after 24 hours',
                        style: theme.textTheme.muted.copyWith(fontSize: 12),
                      ),
                  ],
                ),
              ),
              ShadTooltip(
                builder: (_) => const Text('Sign out'),
                child: ShadIconButton.ghost(
                  icon: const Icon(LucideIcons.logOut, size: 16),
                  onPressed: () => run(() => _signOut(ref)),
                ),
              ),
            ],
          )
        : ShadTooltip(
            builder: (_) => Text(
              user.isDemo ? 'Sign out of demo' : 'Sign out ${user.email}',
            ),
            child: ShadIconButton.ghost(
              icon: const Icon(LucideIcons.logOut, size: 18),
              onPressed: () => _signOut(ref),
            ),
          );

    return ColoredBox(
      color: cs.muted.withValues(alpha: .35),
      child: SafeArea(
        right: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: expanded ? 12 : 8,
            vertical: 14,
          ),
          child: Column(
            crossAxisAlignment: expanded
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.center,
            children: [
              Padding(
                padding: EdgeInsets.only(left: expanded ? 6 : 0, bottom: 18),
                child: Row(
                  mainAxisAlignment: expanded
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    expanded ? const Logo(size: 17) : const LogoMark(size: 22),
                    if (expanded && (user?.isDemo ?? false)) ...[
                      const SizedBox(width: 10),
                      const ShadBadge.outline(child: Text('Demo')),
                    ],
                  ],
                ),
              ),
              if (!expanded && (user?.isDemo ?? false))
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: ShadTooltip(
                    builder: (_) => const Text('Demo session, deleted after 24 hours'),
                    child: ShadBadge.outline(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      child: Text('Demo', style: theme.textTheme.muted.copyWith(fontSize: 10)),
                    ),
                  ),
                ),
              item(
                LucideIcons.squarePen,
                'New chat',
                () => run(chat.newChat),
                primary: true,
              ),
              const SizedBox(height: 6),
              if (onHistory != null)
                item(LucideIcons.history, 'History', () => run(onHistory!)),
              const Spacer(),
              if (models.length > 1) ...[
                if (expanded) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 6),
                    child: Text(
                      'Model',
                      style: theme.textTheme.muted.copyWith(fontSize: 12),
                    ),
                  ),
                  ShadSelect<String>(
                    initialValue: model,
                    minWidth: navExpandedWidth - 24,
                    onChanged: (m) {
                      if (m != null) chat.setModel(m);
                    },
                    options: [
                      for (final m in models)
                        ShadOption(value: m, child: Text(m)),
                    ],
                    selectedOptionBuilder: (_, v) => Row(
                      children: [
                        Icon(
                          LucideIcons.cpu,
                          size: 14,
                          color: cs.mutedForeground,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            v,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.small,
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else
                  item(
                    LucideIcons.cpu,
                    'Model: ${model ?? ''}',
                    () => _pickModel(context, ref, models, model),
                  ),
                const SizedBox(height: 12),
              ],
              Divider(height: 1, color: cs.border),
              const SizedBox(height: 12),
              account,
            ],
          ),
        ),
      ),
    );
  }

  void _signOut(WidgetRef ref) {
    ref.read(chatProvider.notifier).newChat();
    ref.read(authProvider.notifier).signOut();
  }

  void _pickModel(
    BuildContext context,
    WidgetRef ref,
    List<String> models,
    String? current,
  ) {
    showShadDialog(
      context: context,
      builder: (ctx) => ShadDialog(
        title: const Text('Model'),
        description: const Text('Runs locally with Ollama. Smaller is faster.'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in models)
              SizedBox(
                width: double.infinity,
                child: ShadButton.ghost(
                  mainAxisAlignment: MainAxisAlignment.start,
                  leading: Icon(
                    m == current ? LucideIcons.check : null,
                    size: 16,
                  ),
                  onPressed: () {
                    ref.read(chatProvider.notifier).setModel(m);
                    Navigator.of(ctx).pop();
                  },
                  child: Text(m),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
