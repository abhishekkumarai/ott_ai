import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../api/api.dart';
import '../chat/chat_controller.dart';
import '../chat/models.dart';
import '../theme.dart';
import '../widgets/tappable.dart';

/// The user's conversations, refetched whenever a chat is started/switched or a
/// reply finishes (so new chats and updated titles show up without a reload).
final historyProvider = FutureProvider.autoDispose<List<Conversation>>((
  ref,
) async {
  ref.watch(chatProvider.select((s) => (s.conversationId, s.sending)));
  return ref.read(chatProvider.notifier).conversations();
});

enum _Group { today, yesterday, earlier }

_Group _groupOf(DateTime t) {
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final local = t.toLocal();
  final d = DateTime(local.year, local.month, local.day);
  if (!d.isBefore(day)) return _Group.today;
  if (!d.isBefore(day.subtract(const Duration(days: 1)))) {
    return _Group.yesterday;
  }
  return _Group.earlier;
}

/// Topic icon from the title (cheap keyword match; falls back to a chat bubble).
IconData _iconFor(String title) {
  final t = title.toLowerCase();
  bool any(List<String> w) => w.any(t.contains);
  if (any(['guitar', 'piano', 'music', 'song', 'chord', 'jazz'])) {
    return LucideIcons.music;
  }
  if (any(['bread', 'cook', 'recipe', 'bake', 'food', 'coffee', 'espresso'])) {
    return LucideIcons.chefHat;
  }
  if (any(['workout', 'fitness', 'yoga', 'hiit', 'exercise'])) {
    return LucideIcons.dumbbell;
  }
  if (any(['space', 'black hole', 'physics', 'quantum', 'star', 'planet'])) {
    return LucideIcons.orbit;
  }
  if (any(['code', 'python', 'program', 'javascript', 'flutter'])) {
    return LucideIcons.code;
  }
  return LucideIcons.messageSquare;
}

class HistoryList extends ConsumerWidget {
  const HistoryList({super.key, this.onOpened, this.query = ''});

  /// Called after a conversation is opened (e.g. to close a sheet on phones).
  final VoidCallback? onOpened;

  /// Case-insensitive title filter from the sidebar search box.
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final history = ref.watch(historyProvider);
    final activeId = ref.watch(chatProvider.select((s) => s.conversationId));
    final chat = ref.read(chatProvider.notifier);
    final all = history.value;

    if (all == null) {
      return history.hasError
          ? _Message('Couldn’t load your chats.', theme)
          : Center(
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.mutedForeground,
                ),
              ),
            );
    }
    final q = query.trim().toLowerCase();
    final items = q.isEmpty
        ? all
        : [
            for (final c in all)
              if (c.title.toLowerCase().contains(q)) c,
          ];
    if (all.isEmpty) {
      return _Message('No chats yet. Ask for a video to start one.', theme);
    }
    if (items.isEmpty) return _Message('No chats match “$query”.', theme);

    final rows = <Widget>[];
    _Group? current;
    for (final c in items) {
      final g = _groupOf(c.updatedAt);
      if (g != current) {
        current = g;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
            child: Text(switch (g) {
              _Group.today => 'TODAY',
              _Group.yesterday => 'YESTERDAY',
              _Group.earlier => 'EARLIER',
            }, style: mono(context, size: 11)),
          ),
        );
      }
      rows.add(
        _Row(
          conversation: c,
          active: c.id == activeId,
          onOpen: () async {
            await chat.open(c);
            onOpened?.call();
          },
          onDelete: () async {
            try {
              await chat.deleteConversation(c.id);
              ref.invalidate(historyProvider);
            } on ApiException catch (e) {
              if (context.mounted) {
                ShadToaster.of(
                  context,
                ).show(ShadToast.destructive(description: Text(e.message)));
              }
            }
          },
        ),
      );
    }
    return ListView(padding: const EdgeInsets.only(bottom: 12), children: rows);
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.conversation,
    required this.active,
    required this.onOpen,
    required this.onDelete,
  });
  final Conversation conversation;
  final bool active;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final c = widget.conversation;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tappable(
        onTap: widget.onOpen,
        selected: widget.active,
        radius: 10,
        padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
        semanticLabel: 'Open chat ${c.title}',
        child: Row(
          children: [
            Icon(_iconFor(c.title), size: 15, color: cs.mutedForeground),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                c.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.small.copyWith(
                  fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (widget.active && !_hover)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: coral,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox.square(dimension: 7),
                ),
              ),
            HoverReveal(
              hovered: _hover,
              child: ShadTooltip(
                builder: (_) => const Text('Delete chat'),
                child: ShadIconButton.ghost(
                  width: 30,
                  height: 30,
                  icon: Icon(
                    LucideIcons.trash2,
                    size: 14,
                    color: cs.mutedForeground,
                  ),
                  onPressed: widget.onDelete,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, this.theme);
  final String text;
  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
    child: Text(text, style: theme.textTheme.muted),
  );
}
