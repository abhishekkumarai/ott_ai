import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../api/api.dart';
import '../auth/auth.dart';
import '../chat/models.dart';
import '../theme.dart';
import '../widgets/tappable.dart';

/// The user's library ("Save to practice routine", OTTAI-16), newest first.
class SavedController extends Notifier<List<Video>?> {
  @override
  List<Video>? build() {
    // Reload whenever a different user signs in; null until loaded.
    final userId = ref.watch(authProvider.select((a) => a.user?.id));
    if (userId != null) Future.microtask(_load);
    return null;
  }

  ApiClient get _api => ref.read(apiProvider);

  Future<void> _load() async {
    try {
      final data = await _api.get('/me/saved') as List;
      if (!ref.mounted) return;
      state = [for (final v in data) Video.fromJson(v as Map<String, dynamic>)];
    } on ApiException {
      if (ref.mounted) state = state ?? const [];
    }
  }

  bool isSaved(String youtubeId) =>
      state?.any((v) => v.youtubeId == youtubeId) ?? false;

  /// Idempotent server-side; optimistic here, reverted if the request fails.
  Future<void> save(Video v) async {
    if (isSaved(v.youtubeId)) return;
    final before = state;
    state = [v, ...?state];
    try {
      await _api.put('/me/saved/${v.youtubeId}');
    } on ApiException {
      if (ref.mounted) state = before;
      rethrow;
    }
  }

  Future<void> remove(String youtubeId) async {
    final before = state;
    state = [
      for (final v in state ?? const <Video>[])
        if (v.youtubeId != youtubeId) v,
    ];
    try {
      await _api.delete('/me/saved/$youtubeId');
    } on ApiException {
      if (ref.mounted) state = before;
      rethrow;
    }
  }

  Future<void> toggle(Video v) =>
      isSaved(v.youtubeId) ? remove(v.youtubeId) : save(v);
}

final savedProvider = NotifierProvider<SavedController, List<Video>?>(
  SavedController.new,
);

/// Save / Saved toggle for a video.
class SaveButton extends ConsumerWidget {
  const SaveButton({super.key, required this.video, this.iconOnly = false});
  final Video video;
  final bool iconOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(
      savedProvider.select(
        (l) => l?.any((v) => v.youtubeId == video.youtubeId) ?? false,
      ),
    );
    Future<void> toggle() async {
      try {
        await ref.read(savedProvider.notifier).toggle(video);
      } on ApiException catch (e) {
        if (context.mounted) {
          ShadToaster.of(
            context,
          ).show(ShadToast.destructive(description: Text(e.message)));
        }
      }
    }

    final icon = Icon(
      saved ? LucideIcons.bookmarkCheck : LucideIcons.bookmarkPlus,
      size: iconOnly ? 16 : 14,
      color: saved ? coralOn(context) : null,
    );
    if (iconOnly) {
      return ShadTooltip(
        builder: (_) => Text(saved ? 'Remove from library' : 'Save to library'),
        child: ShadIconButton.ghost(
          width: 32,
          height: 32,
          icon: icon,
          onPressed: toggle,
        ),
      );
    }
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      leading: icon,
      onPressed: toggle,
      child: Text(saved ? 'Saved' : 'Save to practice routine'),
    );
  }
}

/// Saved videos list for the sidebar / sheet: click to play, remove on hover.
class SavedList extends ConsumerWidget {
  const SavedList({super.key, required this.onPlay, this.query = ''});
  final void Function(Video) onPlay;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final all = ref.watch(savedProvider);
    if (all == null) {
      return Center(
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
            for (final v in all)
              if (v.title.toLowerCase().contains(q) ||
                  v.channel.toLowerCase().contains(q))
                v,
          ];
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        child: Text(
          all.isEmpty
              ? 'Nothing saved yet. Use “Save to practice routine” on a video, or say “save this”.'
              : 'No saved videos match “$query”.',
          style: theme.textTheme.muted,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: 6, bottom: 12),
      children: [
        for (final v in items)
          _SavedRow(
            video: v,
            onPlay: () => onPlay(v),
            onRemove: () async {
              try {
                await ref.read(savedProvider.notifier).remove(v.youtubeId);
              } on ApiException catch (e) {
                if (context.mounted) {
                  ShadToaster.of(
                    context,
                  ).show(ShadToast.destructive(description: Text(e.message)));
                }
              }
            },
          ),
      ],
    );
  }
}

class _SavedRow extends StatefulWidget {
  const _SavedRow({
    required this.video,
    required this.onPlay,
    required this.onRemove,
  });
  final Video video;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  State<_SavedRow> createState() => _SavedRowState();
}

class _SavedRowState extends State<_SavedRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final v = widget.video;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tappable(
        onTap: widget.onPlay,
        radius: 10,
        padding: const EdgeInsets.fromLTRB(6, 5, 2, 5),
        semanticLabel: 'Play ${v.title}',
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                v.thumbnail,
                width: 64,
                height: 36,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: cs.muted,
                  child: const SizedBox(width: 64, height: 36),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.small.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    v.channel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.muted.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
            HoverReveal(
              hovered: _hover,
              child: ShadTooltip(
                builder: (_) => const Text('Remove from library'),
                child: ShadIconButton.ghost(
                  width: 30,
                  height: 30,
                  icon: Icon(
                    LucideIcons.x,
                    size: 14,
                    color: cs.mutedForeground,
                  ),
                  onPressed: widget.onRemove,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
