import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../auth/auth.dart';
import '../chat/chat_controller.dart';
import '../library/saved.dart';
import '../theme.dart';
import '../widgets/logo.dart';
import 'history.dart';
import 'shortcuts.dart';

/// Left navigation (OTTAI-10). [expanded] shows labels, search and the history
/// list (wide screens and the phone menu sheet); otherwise it is an icon rail and
/// [onHistory] opens the history as a sheet.
class SideNav extends ConsumerStatefulWidget {
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
  ConsumerState<SideNav> createState() => _SideNavState();
}

enum _List { chats, saved }

class _SideNavState extends ConsumerState<SideNav> {
  String _query = '';
  _List _list = _List.chats;

  void _run(VoidCallback f) {
    f();
    widget.onNavigate?.call();
  }

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    final expanded = widget.expanded;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(cs.muted.withValues(alpha: .45), cs.background),
      ),
      child: SafeArea(
        right: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: expanded ? 14 : 8,
            vertical: 14,
          ),
          child: expanded ? _expanded(context) : _rail(context),
        ),
      ),
    );
  }

  Widget _expanded(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final chat = ref.read(chatProvider.notifier);
    final user = ref.watch(authProvider.select((a) => a.user));
    final aiOn = ref.watch(chatProvider.select((s) => s.models.isNotEmpty));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Logo(size: 18),
              if (user?.isDemo ?? false)
                const ShadBadge.outline(child: Text('Demo')),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 16),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: aiOn ? success : cs.mutedForeground,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox.square(dimension: 6),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  aiOn ? 'AI companion active' : 'AI offline · keyword search',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.muted.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        ShadTooltip(
          builder: (_) => Text('New discovery session  ${shortcutLabel('N')}'),
          child: ShadButton(
            onPressed: () => _run(chat.newChat),
            leading: const Icon(LucideIcons.plus, size: 16),
            expands: true,
            child: const Text(
              'New discovery session',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 10),
        ShadInput(
          placeholder: Text(
            _list == _List.chats
                ? 'Search conversations…'
                : 'Search saved videos…',
          ),
          leading: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(
              LucideIcons.search,
              size: 15,
              color: cs.mutedForeground,
            ),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 10),
        _ListSwitch(
          value: _list,
          savedCount: ref.watch(savedProvider.select((l) => l?.length)),
          onChanged: (v) => setState(() => _list = v),
        ),
        Expanded(
          child: _list == _List.chats
              ? HistoryList(query: _query, onOpened: widget.onNavigate)
              : SavedList(
                  query: _query,
                  onPlay: (v) => _run(() => chat.play(v)),
                ),
        ),
        Divider(height: 1, color: cs.border),
        const SizedBox(height: 10),
        _navButton(
          LucideIcons.settings,
          'Settings',
          () => _run(() => context.go('/settings')),
        ),
        _navButton(
          LucideIcons.keyboard,
          'Keyboard shortcuts',
          () => _run(() => showShortcutsDialog(context)),
          trailing: Text('?', style: mono(context, size: 11)),
        ),
        const SizedBox(height: 8),
        if (user != null) _ProfileCard(onSignOut: () => _run(_signOut)),
      ],
    );
  }

  Widget _navButton(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Widget? trailing,
  }) => ShadButton.ghost(
    onPressed: onTap,
    leading: Icon(icon, size: 16),
    trailing: trailing,
    mainAxisAlignment: MainAxisAlignment.start,
    expands: true,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );

  Widget _rail(BuildContext context) {
    final chat = ref.read(chatProvider.notifier);
    final user = ref.watch(authProvider.select((a) => a.user));

    Widget icon(
      IconData i,
      String tip,
      VoidCallback onTap, {
      bool primary = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ShadTooltip(
        builder: (_) => Text(tip),
        child: primary
            ? ShadIconButton(icon: Icon(i, size: 18), onPressed: onTap)
            : ShadIconButton.ghost(icon: Icon(i, size: 18), onPressed: onTap),
      ),
    );

    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 18),
          child: LogoMark(size: 24),
        ),
        if (user?.isDemo ?? false)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: ShadBadge.outline(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              child: Text('Demo', style: TextStyle(fontSize: 10)),
            ),
          ),
        icon(
          LucideIcons.plus,
          'New discovery session  ${shortcutLabel('N')}',
          chat.newChat,
          primary: true,
        ),
        if (widget.onHistory != null)
          icon(LucideIcons.history, 'History', widget.onHistory!),
        icon(
          LucideIcons.bookmark,
          'Saved videos',
          () => showSavedSheet(context),
        ),
        const Spacer(),
        icon(LucideIcons.settings, 'Settings', () => context.go('/settings')),
        icon(
          LucideIcons.keyboard,
          'Keyboard shortcuts  ?',
          () => showShortcutsDialog(context),
        ),
        if (user != null)
          icon(
            LucideIcons.logOut,
            user.isDemo ? 'Sign out of demo' : 'Sign out ${user.email}',
            _signOut,
          ),
      ],
    );
  }

  void _signOut() {
    ref.read(chatProvider.notifier).newChat();
    ref.read(authProvider.notifier).signOut();
  }
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.onSignOut});
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final user = ref.watch(authProvider.select((a) => a.user))!;
    final initials = user.isDemo
        ? 'D'
        : user.email.substring(0, 1).toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.card,
        border: Border.all(color: cs.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        child: Row(
          children: [
            ShadAvatar(
              null,
              size: const Size.square(32),
              backgroundColor: coralSoftOn(context),
              placeholder: Text(
                initials,
                style: theme.textTheme.small.copyWith(
                  color: coralOn(context),
                  fontWeight: FontWeight.w700,
                ),
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
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    user.isDemo ? 'Deleted after 24 hours' : 'Signed in',
                    style: theme.textTheme.muted.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
            ShadTooltip(
              builder: (_) => const Text('Sign out'),
              child: ShadIconButton.ghost(
                width: 32,
                height: 32,
                icon: const Icon(LucideIcons.logOut, size: 16),
                onPressed: onSignOut,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Chats | Saved" segmented switch above the sidebar list (OTTAI-16).
class _ListSwitch extends StatelessWidget {
  const _ListSwitch({
    required this.value,
    required this.savedCount,
    required this.onChanged,
  });
  final _List value;
  final int? savedCount;
  final ValueChanged<_List> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    Widget tab(_List t, IconData icon, String label) {
      final selected = t == value;
      final child = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
      return Expanded(
        child: selected
            ? ShadButton.secondary(
                size: ShadButtonSize.sm,
                leading: Icon(icon, size: 14),
                decoration: ShadDecoration(
                  border: ShadBorder.all(radius: BorderRadius.circular(8)),
                ),
                backgroundColor: cs.card,
                onPressed: () {},
                child: child,
              )
            : ShadButton.ghost(
                size: ShadButtonSize.sm,
                leading: Icon(icon, size: 14),
                foregroundColor: cs.mutedForeground,
                onPressed: () => onChanged(t),
                child: child,
              ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.muted,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            tab(_List.chats, LucideIcons.messageSquare, 'Chats'),
            const SizedBox(width: 3),
            tab(
              _List.saved,
              LucideIcons.bookmark,
              savedCount == null || savedCount == 0
                  ? 'Saved'
                  : 'Saved · $savedCount',
            ),
          ],
        ),
      ),
    );
  }
}

/// Saved videos as a sheet (icon rail / phones).
void showSavedSheet(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  showShadSheet(
    context: context,
    side: ShadSheetSide.left,
    builder: (ctx) => ShadSheet(
      title: const Text('Saved videos'),
      padding: const EdgeInsets.fromLTRB(12, 20, 8, 0),
      constraints: BoxConstraints(
        maxWidth: width < 420 ? width * .88 : navExpandedWidth + 24,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height - 90,
        child: Consumer(
          builder: (context, ref, _) => SavedList(
            onPlay: (v) {
              Navigator.of(ctx).pop();
              ref.read(chatProvider.notifier).play(v);
            },
          ),
        ),
      ),
    ),
  );
}
