import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../chat/models.dart';
import '../chat/widgets.dart';
import '../library/saved.dart';
import '../player/mini_player.dart';
import '../settings/preferences.dart';
import '../theme.dart';
import '../widgets/tappable.dart';

/// Right-hand column on desktop (OTTAI-23): the docked mini-player on top, then
/// the "Recommended" list for the latest reply (or an earlier one, OTTAI-24).
class RecommendedRail extends ConsumerWidget {
  const RecommendedRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = ShadTheme.of(context).colorScheme;
    final playerOpen = ref.watch(chatProvider.select((s) => s.playerOpen));
    // In theater mode the large player sits left of the rail; the rail keeps
    // only its list.
    final docked =
        playerOpen && ref.watch(playerModeProvider) == PlayerMode.mini;
    return ColoredBox(
      color: Color.alphaBlend(cs.muted.withValues(alpha: .3), cs.background),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (docked)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: MiniPlayer(docked: true),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 12, 6),
            child: RecommendedHeader(),
          ),
          const Expanded(
            child: RecommendedList(padding: EdgeInsets.fromLTRB(8, 0, 8, 12)),
          ),
        ],
      ),
    );
  }
}

/// "Recommended", or "Recommended · earlier: ‹title›" with "Back to latest".
class RecommendedHeader extends ConsumerWidget {
  const RecommendedHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final s = ref.watch(chatProvider);
    final i = s.railIndex;
    final earlier = s.railShowsEarlier && i != null
        ? s.messages[i].videos.first.title
        : null;
    final count = i == null ? 0 : s.recommendationsFor(i).length;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(LucideIcons.sparkles, size: 15, color: coralOn(context)),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Recommended'),
                if (earlier != null)
                  TextSpan(
                    text: ' · earlier: $earlier',
                    style: theme.textTheme.muted.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                  )
                else if (count > 0)
                  TextSpan(text: '  $count', style: mono(context, size: 11)),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        if (earlier != null)
          ShadButton.link(
            size: ShadButtonSize.sm,
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            foregroundColor: coralOn(context),
            onPressed: ref.read(chatProvider.notifier).backToLatest,
            child: const Text('Back to latest'),
          ),
      ],
    );
  }
}

/// The rail's rows: click to play in place; the playing one is highlighted and
/// ones already played in this chat are dimmed and marked "Watched".
class RecommendedList extends ConsumerWidget {
  const RecommendedList({super.key, this.padding = EdgeInsets.zero});
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final s = ref.watch(chatProvider);
    final i = s.railIndex;
    final rows = s.rail;
    if (rows.isEmpty) {
      return Padding(
        padding: padding.add(const EdgeInsets.symmetric(horizontal: 8)),
        child: Text(
          i == null
              ? 'Ask about a topic; related videos show up here.'
              : s.loadingFor(i)
              ? 'Finding related videos…'
              : 'No recommendations for this reply.',
          style: theme.textTheme.muted.copyWith(fontSize: 13),
        ),
      );
    }
    final chat = ref.read(chatProvider.notifier);
    return ListView.builder(
      padding: padding,
      itemCount: rows.length,
      itemBuilder: (_, n) {
        final v = rows[n];
        final playing = s.nowPlaying?.youtubeId == v.youtubeId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: RailRow(
            video: v,
            playing: playing,
            watched: !playing && s.played.contains(v.youtubeId),
            onTap: playing ? null : () => chat.play(v),
          ),
        );
      },
    );
  }
}

class RailRow extends StatefulWidget {
  const RailRow({
    super.key,
    required this.video,
    required this.onTap,
    this.playing = false,
    this.watched = false,
  });
  final Video video;
  final VoidCallback? onTap;
  final bool playing;
  final bool watched;

  @override
  State<RailRow> createState() => _RailRowState();
}

class _RailRowState extends State<RailRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final v = widget.video;
    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          v.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.small.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.3,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          v.channel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.muted.copyWith(fontSize: 12),
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            if (v.match != null) MatchBadge(v.match!),
            if (widget.playing)
              _Tag('PLAYING', color: coralOn(context))
            else if (widget.watched)
              const _Tag('WATCHED'),
          ],
        ),
      ],
    );
    final row = Tappable(
      onTap: widget.onTap,
      selected: widget.playing,
      radius: 12,
      padding: const EdgeInsets.all(6),
      semanticLabel: widget.playing ? 'Playing ${v.title}' : 'Play ${v.title}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Opacity(
              opacity: widget.watched ? .55 : 1,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 144,
                    child: Thumbnail(video: v, radius: 8, showMatch: false),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: meta),
                ],
              ),
            ),
          ),
          HoverReveal(
            hovered: _hover || widget.playing,
            child: SaveButton(video: v, iconOnly: true),
          ),
        ],
      ),
    );
    final decorated = widget.playing
        ? DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: coralSoftBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: row,
          )
        : row;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: decorated,
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => ShadBadge.outline(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
    foregroundColor: color,
    child: Text(label, style: mono(context, size: 10, color: color)),
  );
}

/// Tablet: the rail as a sheet from the right (the mini-player keeps floating).
void showRecommendedSheet(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  showShadSheet(
    context: context,
    side: ShadSheetSide.right,
    builder: (ctx) => ShadSheet(
      padding: const EdgeInsets.fromLTRB(12, 20, 8, 0),
      constraints: BoxConstraints(
        maxWidth: width < 480 ? width * .92 : railWidth + 24,
      ),
      title: const Padding(
        padding: EdgeInsets.only(left: 4, right: 24),
        child: RecommendedHeader(),
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height - 90,
        child: const RecommendedList(padding: EdgeInsets.only(bottom: 12)),
      ),
    ),
  );
}

/// Top-bar button that opens the rail sheet (tablet widths).
class RecommendedButton extends ConsumerWidget {
  const RecommendedButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(chatProvider.select((s) => s.rail.length));
    return ShadTooltip(
      builder: (_) => const Text('Videos related to the latest reply'),
      child: ShadButton.outline(
        size: ShadButtonSize.sm,
        leading: const Icon(LucideIcons.panelRight, size: 15),
        onPressed: () => showRecommendedSheet(context),
        child: Text(count == 0 ? 'Recommended' : 'Recommended · $count'),
      ),
    );
  }
}
