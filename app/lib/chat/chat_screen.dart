import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../auth/auth.dart';
import '../player/player_overlay.dart';
import '../theme.dart';
import '../widgets/logo.dart';
import 'chat_controller.dart';
import 'models.dart';
import 'widgets.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final playerOpen = ref.watch(chatProvider.select((s) => s.playerOpen));
    return Scaffold(
      backgroundColor: cs.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _TopBar(),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Keep the chat mounted underneath so its scroll position survives.
                  Offstage(
                    offstage: playerOpen,
                    child: ExcludeFocus(excluding: playerOpen, child: const _ChatBody()),
                  ),
                  if (playerOpen) const Positioned.fill(child: PlayerOverlay()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final s = ref.watch(chatProvider);
    final chat = ref.read(chatProvider.notifier);
    final narrow = MediaQuery.sizeOf(context).width < 600;

    return DecoratedBox(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: cs.border))),
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              const Logo(),
              const Spacer(),
              if (s.models.length > 1)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: narrow ? 130 : 180),
                  child: ShadSelect<String>(
                    initialValue: s.model,
                    minWidth: narrow ? 120 : 160,
                    onChanged: (m) {
                      if (m != null) chat.setModel(m);
                    },
                    options: [
                      for (final m in s.models) ShadOption(value: m, child: Text(m)),
                    ],
                    selectedOptionBuilder: (_, v) =>
                        Text(v, overflow: TextOverflow.ellipsis, style: theme.textTheme.small),
                  ),
                ),
              const SizedBox(width: 4),
              ShadTooltip(
                builder: (_) => const Text('History'),
                child: ShadIconButton.ghost(
                  icon: const Icon(LucideIcons.history, size: 18),
                  onPressed: () => _showHistory(context, ref),
                ),
              ),
              ShadTooltip(
                builder: (_) => const Text('New chat'),
                child: ShadIconButton.ghost(
                  icon: const Icon(LucideIcons.squarePen, size: 18),
                  onPressed: chat.newChat,
                ),
              ),
              ShadTooltip(
                builder: (_) => Text('Sign out ${ref.read(authProvider).user?.email ?? ''}'),
                child: ShadIconButton.ghost(
                  icon: const Icon(LucideIcons.logOut, size: 18),
                  onPressed: () {
                    chat.newChat();
                    ref.read(authProvider.notifier).signOut();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHistory(BuildContext context, WidgetRef ref) {
    final chat = ref.read(chatProvider.notifier);
    final wide = MediaQuery.sizeOf(context).width >= 600;
    showShadSheet(
      context: context,
      side: wide ? ShadSheetSide.left : ShadSheetSide.bottom,
      builder: (ctx) => ShadSheet(
        title: const Text('Your chats'),
        constraints: wide ? const BoxConstraints(maxWidth: 380) : const BoxConstraints(maxHeight: 520),
        child: FutureBuilder<List<Conversation>>(
          future: chat.conversations(),
          builder: (ctx, snap) {
            final theme = ShadTheme.of(ctx);
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(24), child: Center(child: TypingIndicator()));
            }
            final items = snap.data ?? const [];
            if (snap.hasError || items.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(snap.hasError ? 'Couldn’t load your chats.' : 'No chats yet.',
                    style: theme.textTheme.muted),
              );
            }
            return Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in items)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 4),
                      leading: const Icon(LucideIcons.messageSquare, size: 16),
                      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.small),
                      trailing: ShadIconButton.ghost(
                        icon: const Icon(LucideIcons.trash2, size: 15),
                        onPressed: () async {
                          Navigator.of(ctx).pop();
                          await chat.deleteConversation(c.id);
                        },
                      ),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        chat.open(c);
                      },
                    ),
                ],
              ),
            );
          },
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
        ShadToaster.of(context).show(ShadToast.destructive(description: Text(err)));
      }
    });

    final list = s.messages.isEmpty
        ? const _EmptyState()
        : ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: EdgeInsets.fromLTRB(narrow ? 16 : 24, 24, narrow ? 16 : 24, 12),
            itemCount: s.messages.length + (s.sending ? 1 : 0),
            itemBuilder: (_, i) {
              if (s.sending && i == 0) {
                return const Padding(
                  padding: EdgeInsets.only(bottom: 18),
                  child: Align(alignment: Alignment.centerLeft, child: TypingIndicator()),
                );
              }
              final m = s.messages[s.messages.length - 1 - (i - (s.sending ? 1 : 0))];
              return Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: contentMaxWidth),
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
          padding: EdgeInsets.fromLTRB(narrow ? 12 : 24, 0, narrow ? 12 : 24, 12),
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
                    style: theme.textTheme.muted.copyWith(fontSize: 12, color: cs.mutedForeground),
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
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What do you want to watch?', style: theme.textTheme.h2.copyWith(letterSpacing: -0.6)),
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

