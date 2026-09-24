import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../auth/auth.dart';
import '../player/player_overlay.dart';
import '../theme.dart';
import '../shell/history.dart';
import '../shell/right_panel.dart';
import '../shell/side_nav.dart';
import '../widgets/logo.dart';
import 'chat_controller.dart';
import 'widgets.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final playerOpen = ref.watch(chatProvider.select((s) => s.playerOpen));
    final width = MediaQuery.sizeOf(context).width;
    final mobile = width < mobileBreakpoint;
    final showRight = width >= rightPanelBreakpoint;

    final main = Stack(
      fit: StackFit.expand,
      children: [
        // Keep the chat mounted underneath so its scroll position survives.
        Offstage(
          offstage: playerOpen,
          child: ExcludeFocus(excluding: playerOpen, child: const _ChatBody()),
        ),
        if (playerOpen)
          Positioned.fill(
            child: PlayerOverlay(inlineRecommendations: !showRight),
          ),
      ],
    );

    return Scaffold(
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
                  width: width >= navExpandedBreakpoint
                      ? navExpandedWidth
                      : navRailWidth,
                  child: SideNav(
                    expanded: width >= navExpandedBreakpoint,
                    onHistory: showRight
                        ? null
                        : () => showHistorySheet(context),
                  ),
                ),
                VerticalDivider(width: 1, color: cs.border),
                Expanded(
                  child: SafeArea(
                    left: false,
                    right: false,
                    bottom: false,
                    child: main,
                  ),
                ),
                if (showRight) ...[
                  VerticalDivider(width: 1, color: cs.border),
                  const SizedBox(width: rightPanelWidth, child: RightPanel()),
                ],
              ],
            ),
    );
  }
}

/// History as a right-hand sheet when the right panel isn't on screen.
void showHistorySheet(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  showShadSheet(
    context: context,
    side: ShadSheetSide.right,
    builder: (ctx) => ShadSheet(
      title: const Text('History'),
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 0),
      constraints: BoxConstraints(
        maxWidth: width < 420 ? width * .88 : rightPanelWidth,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height - 90,
        child: HistoryList(onOpened: () => Navigator.of(ctx).pop()),
      ),
    ),
  );
}

/// Phone top bar: menu (left navigation) · logo · history (right sheet).
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
              icon: const Icon(LucideIcons.history, size: 19),
              onPressed: () => showHistorySheet(context),
            ),
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

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final s = ref.watch(chatProvider);
    final narrow = MediaQuery.sizeOf(context).width < 600;

    ref.listen(chatProvider.select((s) => s.error), (_, err) {
      if (err != null) {
        ShadToaster.of(
          context,
        ).show(ShadToast.destructive(description: Text(err)));
      }
    });

    final list = s.messages.isEmpty
        ? const _EmptyState()
        : ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: EdgeInsets.fromLTRB(
              narrow ? 12 : 24,
              24,
              narrow ? 12 : 24,
              12,
            ),
            itemCount: s.messages.length + (s.sending ? 1 : 0),
            itemBuilder: (_, i) {
              if (s.sending && i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: contentMaxWidth,
                      ),
                      child: const Align(
                        alignment: Alignment.centerLeft,
                        child: TypingIndicator(),
                      ),
                    ),
                  ),
                );
              }
              final m =
                  s.messages[s.messages.length - 1 - (i - (s.sending ? 1 : 0))];
              return Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: contentMaxWidth,
                    ),
                    child: MessageBubble(message: m),
                  ),
                ),
              );
            },
          );

    return Column(
      children: [
        Expanded(child: list),
        Padding(
          padding: EdgeInsets.fromLTRB(
            narrow ? 12 : 24,
            0,
            narrow ? 12 : 24,
            12,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: contentMaxWidth),
              child: Column(
                children: [
                  const Composer(autofocus: true),
                  const SizedBox(height: 8),
                  Text(
                    'Videos play from YouTube. Say “forward 25 sec” or “stop” while watching.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.muted.copyWith(
                      fontSize: 12,
                      color: cs.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
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
                'What do you want to watch?',
                style: theme.textTheme.h2.copyWith(letterSpacing: -0.6),
              ),
              const SizedBox(height: 8),
              Text(
                'Ask about any topic. I’ll find a free video and play it right here.',
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
