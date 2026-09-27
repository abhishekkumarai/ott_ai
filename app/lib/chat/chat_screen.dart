import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../auth/auth.dart';
import '../player/mini_player.dart';
import '../player/player_overlay.dart';
import '../settings/preferences.dart';
import '../shell/history.dart';
import '../shell/shortcuts.dart';
import '../shell/side_nav.dart';
import '../shell/top_bar.dart';
import '../theme.dart';
import '../widgets/logo.dart';
import 'chat_controller.dart';
import 'models.dart';
import 'quick_actions.dart';
import 'reply.dart';
import 'widgets.dart';

/// Chat-first layout (OTTAI-4): the chat is always the main surface; a playing
/// video floats in the mini-player, or takes over the column in theater mode.
class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    // Start loading saved collapse toggles before any reply is built.
    ref.watch(collapseProvider.select((_) => null));
    final playerOpen = ref.watch(chatProvider.select((s) => s.playerOpen));
    final theater =
        playerOpen && ref.watch(playerModeProvider) == PlayerMode.theater;
    final mini = playerOpen && !theater;
    final width = MediaQuery.sizeOf(context).width;
    final mobile = width < mobileBreakpoint;
    final navExpanded = width >= navExpandedBreakpoint;

    final main = Stack(
      fit: StackFit.expand,
      children: [
        // Keep the chat mounted underneath so its scroll position survives.
        Offstage(
          offstage: theater,
          child: ExcludeFocus(excluding: theater, child: const _ChatBody()),
        ),
        if (theater) const Positioned.fill(child: PlayerOverlay()),
        // Only one of PlayerOverlay / MiniPlayer is mounted at a time, so the
        // player view (GlobalKey) moves between them without reloading.
        if (mini)
          mobile
              ? const Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: MiniPlayer(compact: true),
                )
              : Positioned(
                  top: 16,
                  right: 16,
                  width:
                      (width -
                              (navExpanded ? navExpandedWidth : navRailWidth) -
                              32)
                          .clamp(280.0, miniPlayerWidth),
                  child: const MiniPlayer(),
                ),
      ],
    );

    return GlobalShortcuts(
      child: Scaffold(
        backgroundColor: cs.background,
        body: mobile
            ? SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    const _MobileBar(),
                    Expanded(child: main),
                  ],
                ),
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: navExpanded ? navExpandedWidth : navRailWidth,
                    child: SideNav(
                      expanded: navExpanded,
                      onHistory: navExpanded
                          ? null
                          : () => showHistorySheet(context),
                    ),
                  ),
                  VerticalDivider(width: 1, color: cs.border),
                  Expanded(
                    child: SafeArea(
                      left: false,
                      bottom: false,
                      child: Column(
                        children: [
                          const TopBar(),
                          Expanded(child: main),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// History as a sheet when the full sidebar isn't on screen.
void showHistorySheet(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  showShadSheet(
    context: context,
    side: ShadSheetSide.left,
    builder: (ctx) => ShadSheet(
      title: const Text('History'),
      padding: const EdgeInsets.fromLTRB(12, 20, 8, 0),
      constraints: BoxConstraints(
        maxWidth: width < 420 ? width * .88 : navExpandedWidth + 24,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height - 90,
        child: HistoryList(onOpened: () => Navigator.of(ctx).pop()),
      ),
    ),
  );
}

/// Phone top bar: menu (left navigation) · logo · new session.
class _MobileBar extends ConsumerWidget {
  const _MobileBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final isDemo = ref.watch(
      authProvider.select((a) => a.user?.isDemo ?? false),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.border)),
      ),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const SizedBox(width: 4),
            ShadIconButton.ghost(
              icon: const Icon(LucideIcons.menu, size: 20),
              onPressed: () => _openMenu(context),
            ),
            const Logo(size: 16),
            if (isDemo) ...[
              const SizedBox(width: 8),
              const ShadBadge.outline(child: Text('Demo')),
            ],
            const Spacer(),
            ShadIconButton.ghost(
              icon: const Icon(LucideIcons.squarePen, size: 19),
              onPressed: ref.read(chatProvider.notifier).newChat,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  void _openMenu(BuildContext context) {
    showShadSheet(
      context: context,
      side: ShadSheetSide.left,
      builder: (ctx) => ShadSheet(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(maxWidth: navExpandedWidth + 24),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height,
          child: SideNav(
            expanded: true,
            onNavigate: () => Navigator.of(ctx).pop(),
          ),
        ),
      ),
    );
  }
}

class _ChatBody extends ConsumerStatefulWidget {
  const _ChatBody();

  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody> {
  final _scroll = ScrollController();
  final _composerFocus = FocusNode(debugLabel: 'chat-composer');

  /// Show "Scroll to top" once the first message is this far above the view.
  static const _topThreshold = 400.0;
  bool _showTop = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  // The list is reversed, so the first message is at maxScrollExtent and the
  // distance to it is extentAfter.
  void _onScroll() {
    final show =
        _scroll.hasClients && _scroll.position.extentAfter > _topThreshold;
    if (show != _showTop) setState(() => _showTop = show);
  }

  Future<void> _scrollToTop() async {
    final instant = MediaQuery.disableAnimationsOf(context);
    // Items build lazily, so maxScrollExtent grows as we approach it.
    for (var i = 0; i < 5 && _scroll.hasClients; i++) {
      final p = _scroll.position;
      if (p.extentAfter == 0) break;
      if (instant) {
        _scroll.jumpTo(p.maxScrollExtent);
      } else {
        await _scroll.animateTo(
          p.maxScrollExtent,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(chatProvider);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final hPad = narrow ? 12.0 : 24.0;

    // Back to typing here whenever theater mode gives way to the chat.
    ref.listen(playerModeProvider, (_, mode) {
      if (mode != PlayerMode.mini) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _composerFocus.requestFocus();
      });
    });

    ref.listen(chatProvider.select((s) => s.error), (_, err) {
      if (err != null) {
        ShadToaster.of(
          context,
        ).show(ShadToast.destructive(description: Text(err)));
      }
    });

    Widget column(Widget child) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: contentMaxWidth),
        child: child,
      ),
    );

    final list = s.messages.isEmpty
        ? const _EmptyState()
        : ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: EdgeInsets.fromLTRB(hPad, 24, hPad, 12),
            itemCount: s.messages.length + (s.sending ? 1 : 0),
            itemBuilder: (_, i) {
              if (s.sending && i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: column(
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: TypingIndicator(),
                    ),
                  ),
                );
              }
              final index = s.messages.length - 1 - (i - (s.sending ? 1 : 0));
              final m = s.messages[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: column(
                  m.role == Role.user
                      ? UserBubble(message: m)
                      : AssistantReply(message: m, index: index),
                ),
              );
            },
          );

    return Column(
      children: [
        if (!narrow) const SessionBreadcrumb(),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: list),
              if (s.messages.isNotEmpty)
                Positioned(
                  right: hPad,
                  bottom: 12,
                  child: _ScrollToTopButton(
                    visible: _showTop,
                    onPressed: _scrollToTop,
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 12),
          child: column(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (s.playerOpen) ...[
                  const QuickActions(),
                  const SizedBox(height: 8),
                ],
                Composer(
                  autofocus: true,
                  focusNode: _composerFocus,
                  // ← / → seek and Esc stops from the chat too.
                  playerKeys: s.playerOpen,
                ),
                const SizedBox(height: 8),
                ShortcutHint(playing: s.playerOpen),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Floating "Scroll to top" over the message list; hidden (and untappable)
/// near the first message.
class _ScrollToTopButton extends StatelessWidget {
  const _ScrollToTopButton({required this.visible, required this.onPressed});

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: ExcludeSemantics(
          excluding: !visible,
          child: ShadTooltip(
            builder: (_) => const Text('Scroll to top'),
            child: Semantics(
              button: true,
              label: 'Scroll to top',
              child: ShadIconButton.outline(
                width: 40,
                height: 40,
                backgroundColor: cs.card,
                decoration: ShadDecoration(
                  border: ShadBorder.all(
                    radius: BorderRadius.circular(999),
                    color: cs.border,
                  ),
                  shadows: ShadShadows.md,
                ),
                icon: const Icon(LucideIcons.arrowUpToLine, size: 18),
                onPressed: onPressed,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  static const _suggestions = [
    'How do black holes form?',
    'Sourdough bread for beginners',
    'Learn basic guitar chords',
    'Python in 15 minutes',
    'Jazz piano explained',
    'Home workout, no equipment',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Center(
      child: SingleChildScrollView(
        // Same horizontal padding and max width as the composer below, so both
        // share one left edge.
        padding: EdgeInsets.symmetric(
          horizontal: narrow ? 12 : 24,
          vertical: 24,
        ),
        child: ConstrainedBox(
          // Tight width (clamped to what's available) so the column doesn't
          // shrink-wrap its text and drift off-center from the composer.
          constraints: const BoxConstraints.tightFor(width: contentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'What do you want to learn today?',
                style: theme.textTheme.h2.copyWith(
                  letterSpacing: -0.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Ask about any topic. I’ll find free videos with their key '
                'moments; pick one to play it right here.',
                style: theme.textTheme.muted.copyWith(fontSize: 15),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in _suggestions)
                    ShadButton.outline(
                      size: ShadButtonSize.sm,
                      leading: const Icon(LucideIcons.sparkles, size: 13),
                      onPressed: () => ref.read(chatProvider.notifier).send(s),
                      child: Text(s),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
