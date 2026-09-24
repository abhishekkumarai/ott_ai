import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../chat/models.dart';

/// The user's conversations, refetched whenever a chat is started/switched or a
/// reply finishes (so new chats and updated titles show up without a reload).
final historyProvider = FutureProvider.autoDispose<List<Conversation>>((
  ref,
) async {
  ref.watch(chatProvider.select((s) => (s.conversationId, s.sending)));
  return ref.read(chatProvider.notifier).conversations();
});

String _relative(DateTime t) {
  final d = DateTime.now().difference(t.toLocal());
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  return '${t.day}/${t.month}/${t.year}';
}

class HistoryList extends ConsumerWidget {
  const HistoryList({super.key, this.onOpened});

  /// Called after a conversation is opened (e.g. to close a sheet on phones).
  final VoidCallback? onOpened;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final history = ref.watch(historyProvider);
    final activeId = ref.watch(chatProvider.select((s) => s.conversationId));
    final chat = ref.read(chatProvider.notifier);
    final items = history.value;

    if (items == null) {
      return history.hasError
          ? _Message('Couldn’t load your chats.', theme)
          : const Center(
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
    }
    if (items.isEmpty) {
      return _Message('No chats yet. Ask for a video to start one.', theme);
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final c = items[i];
        final active = c.id == activeId;
        return Material(
          color: active ? cs.muted : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            hoverColor: cs.muted.withValues(alpha: .6),
            onTap: () async {
              await chat.open(c);
              onOpened?.call();
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.small.copyWith(
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _relative(c.updatedAt),
                          style: theme.textTheme.muted.copyWith(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  ShadTooltip(
                    builder: (_) => const Text('Delete chat'),
                    child: ShadIconButton.ghost(
                      width: 30,
                      height: 30,
                      icon: Icon(
                        LucideIcons.trash2,
                        size: 14,
                        color: cs.mutedForeground,
                      ),
                      onPressed: () async {
                        await chat.deleteConversation(c.id);
                        ref.invalidate(historyProvider);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, this.theme);
  final String text;
  final ShadThemeData theme;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
    child: Text(text, style: theme.textTheme.muted),
  );
}
