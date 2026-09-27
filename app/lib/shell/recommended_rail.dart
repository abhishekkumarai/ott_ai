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
    final s = ref.watch(chatProvider);
    final activeSeries = _activeSeriesVideo(s);

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
          if (activeSeries != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: SeriesRailHeader(series: activeSeries),
            ),
            Expanded(
              child: SeriesRailContent(
                series: activeSeries,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              ),
            ),
          ] else ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 12, 6),
              child: RecommendedHeader(),
            ),
            const Expanded(
              child: RecommendedList(padding: EdgeInsets.fromLTRB(8, 0, 8, 12)),
            ),
          ],
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
            if (v.provider == 'vidy')
              _Tag(
                v.mediaType == 'tv' && v.season != null && v.episode != null
                    ? 'S${v.season} E${v.episode}'
                    : v.mediaType == 'anime' && v.episode != null
                    ? 'EP ${v.episode}'
                    : v.mediaType.toUpperCase(),
                color: coralOn(context),
              ),
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
    builder: (ctx) => Consumer(
      builder: (context, ref, _) {
        final s = ref.watch(chatProvider);
        final activeSeries = _activeSeriesVideo(s);
        return ShadSheet(
          padding: const EdgeInsets.fromLTRB(12, 20, 8, 0),
          constraints: BoxConstraints(
            maxWidth: width < 480 ? width * .92 : railWidth + 24,
          ),
          title: Padding(
            padding: const EdgeInsets.only(left: 4, right: 24),
            child: activeSeries != null
                ? SeriesRailHeader(series: activeSeries)
                : const RecommendedHeader(),
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height - 90,
            child: activeSeries != null
                ? SeriesRailContent(
                    series: activeSeries,
                    padding: const EdgeInsets.only(bottom: 12),
                  )
                : const RecommendedList(padding: EdgeInsets.only(bottom: 12)),
          ),
        );
      },
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

// ─────────────────────────────────────────────────────────────────────────────
// TV Series & Episodic Anime Rail Extensions (OTTAI-35)
// ─────────────────────────────────────────────────────────────────────────────

bool _isSeries(Video v) =>
    v.mediaType == 'tv' ||
    v.mediaType == 'anime' ||
    v.youtubeId.startsWith('vidy:tv:') ||
    v.youtubeId.startsWith('vidy:anime:');

String _seriesMediaId(Video v) {
  if (v.youtubeId.startsWith('vidy:tv:')) {
    final parts = v.youtubeId.split(':');
    final segs = parts[2].split('/');
    return 'vidy:tv:${segs[0]}';
  }
  if (v.youtubeId.startsWith('vidy:anime:')) {
    final parts = v.youtubeId.split(':');
    final segs = parts[2].split('/');
    return 'vidy:anime:${segs[0]}';
  }
  return v.youtubeId;
}

Video? _activeSeriesVideo(ChatState s) {
  if (s.nowPlaying != null && _isSeries(s.nowPlaying!)) {
    return s.nowPlaying;
  }
  final i = s.railIndex;
  if (i != null && s.messages[i].videos.isNotEmpty) {
    final first = s.messages[i].videos.first;
    if (_isSeries(first)) return first;
  }
  return null;
}

class SeriesRailHeader extends ConsumerWidget {
  const SeriesRailHeader({super.key, required this.series});
  final Video series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(chatProvider);
    final tab = ref.watch(railTabProvider);
    final seriesId = _seriesMediaId(series);
    final season = ref.watch(selectedSeasonProvider(seriesId));
    final episodesAsync = ref.watch(
      seriesEpisodesProvider(SeriesKey(seriesId, season)),
    );
    final epCount = episodesAsync.value?.episodes.length ?? 0;
    final recCount = s.rail.length;

    final i = s.railIndex;
    final earlier = s.railShowsEarlier && i != null
        ? s.messages[i].videos.first.title
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _RailTabButton(
                label: 'Episodes',
                count: epCount,
                icon: LucideIcons.film,
                selected: tab == RailTab.episodes,
                onTap: () =>
                    ref.read(railTabProvider.notifier).select(RailTab.episodes),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _RailTabButton(
                label: 'Recommended',
                count: recCount,
                icon: LucideIcons.sparkles,
                selected: tab == RailTab.recommended,
                onTap: () => ref
                    .read(railTabProvider.notifier)
                    .select(RailTab.recommended),
              ),
            ),
          ],
        ),
        if (tab == RailTab.recommended && earlier != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Earlier: $earlier',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ShadTheme.of(context).textTheme.muted.copyWith(fontSize: 12),
                ),
              ),
              ShadButton.link(
                size: ShadButtonSize.sm,
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                foregroundColor: coralOn(context),
                onPressed: ref.read(chatProvider.notifier).backToLatest,
                child: const Text('Back to latest'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _RailTabButton extends StatelessWidget {
  const _RailTabButton({
    required this.label,
    required this.count,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color = selected ? coralOn(context) : theme.colorScheme.mutedForeground;
    return Tappable(
      onTap: onTap,
      radius: 8,
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? coralOn(context).withValues(alpha: .12)
              : Colors.transparent,
          border: Border.all(
            color: selected ? coralOn(context).withValues(alpha: .6) : theme.colorScheme.border,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                count > 0 ? '$label · $count' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.small.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  fontSize: 12,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SeriesRailContent extends ConsumerWidget {
  const SeriesRailContent({
    super.key,
    required this.series,
    this.padding = EdgeInsets.zero,
  });

  final Video series;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(railTabProvider);
    if (tab == RailTab.episodes) {
      return EpisodeList(series: series, padding: padding);
    }
    return RecommendedList(padding: padding);
  }
}

class EpisodeList extends ConsumerWidget {
  const EpisodeList({
    super.key,
    required this.series,
    this.padding = EdgeInsets.zero,
  });

  final Video series;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final seriesId = _seriesMediaId(series);
    final season = ref.watch(selectedSeasonProvider(seriesId));
    final episodesAsync = ref.watch(
      seriesEpisodesProvider(SeriesKey(seriesId, season)),
    );
    final s = ref.watch(chatProvider);

    return episodesAsync.when(
      loading: () => Padding(
        padding: padding.add(const EdgeInsets.symmetric(horizontal: 8, vertical: 12)),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text('Loading episodes…', style: theme.textTheme.muted.copyWith(fontSize: 13)),
          ],
        ),
      ),
      error: (err, _) => Padding(
        padding: padding.add(const EdgeInsets.symmetric(horizontal: 8, vertical: 12)),
        child: Text(
          'Could not load episodes.',
          style: theme.textTheme.muted.copyWith(fontSize: 13),
        ),
      ),
      data: (data) {
        if (data == null || data.episodes.isEmpty) {
          return Padding(
            padding: padding.add(const EdgeInsets.symmetric(horizontal: 8, vertical: 12)),
            child: Text(
              'No episodes found.',
              style: theme.textTheme.muted.copyWith(fontSize: 13),
            ),
          );
        }

        final seasons = data.seasons;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (seasons.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final sn in seasons) ...[
                        _SeasonChip(
                          season: sn,
                          selected: sn.seasonNumber == season,
                          onTap: () => ref
                              .read(selectedSeasonProvider(seriesId).notifier)
                              .select(sn.seasonNumber),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                padding: padding,
                itemCount: data.episodes.length,
                itemBuilder: (_, n) {
                  final ep = data.episodes[n];
                  final playing = s.nowPlaying?.youtubeId == ep.youtubeId;
                  final watched = !playing && s.played.contains(ep.youtubeId);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: EpisodeRow(
                      episode: ep,
                      playing: playing,
                      watched: watched,
                      onTap: playing
                          ? null
                          : () => ref
                              .read(chatProvider.notifier)
                              .play(ep.toVideo(seriesName: data.seriesTitle)),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class EpisodeRow extends StatefulWidget {
  const EpisodeRow({
    super.key,
    required this.episode,
    required this.onTap,
    this.playing = false,
    this.watched = false,
  });

  final Episode episode;
  final VoidCallback? onTap;
  final bool playing;
  final bool watched;

  @override
  State<EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<EpisodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final ep = widget.episode;
    final epVideo = ep.toVideo();

    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'E${ep.episodeNumber} · ${ep.title}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.small.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.3,
            fontSize: 13,
          ),
        ),
        if (ep.overview.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            ep.overview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.muted.copyWith(fontSize: 11, height: 1.25),
          ),
        ],
        const SizedBox(height: 5),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            _Tag(
              ep.mediaType == 'anime'
                  ? 'EP ${ep.episodeNumber}'
                  : 'S${ep.seasonNumber} E${ep.episodeNumber}',
              color: coralOn(context),
            ),
            if (ep.durationS > 0)
              _Tag(formatTime(ep.durationS)),
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
      semanticLabel: widget.playing
          ? 'Playing Episode ${ep.episodeNumber}: ${ep.title}'
          : 'Play Episode ${ep.episodeNumber}: ${ep.title}',
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
                    width: 130,
                    child: Thumbnail(video: epVideo, radius: 8, showMatch: false),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: meta),
                ],
              ),
            ),
          ),
          HoverReveal(
            hovered: _hover || widget.playing,
            child: SaveButton(video: epVideo, iconOnly: true),
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

class _SeasonChip extends StatelessWidget {
  const _SeasonChip({
    required this.season,
    required this.selected,
    required this.onTap,
  });

  final SeasonInfo season;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final label = season.name.isNotEmpty
        ? season.name
        : 'Season ${season.seasonNumber}';
    return Tappable(
      onTap: onTap,
      radius: 16,
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? coralOn(context).withValues(alpha: .15)
              : theme.colorScheme.muted.withValues(alpha: .4),
          border: Border.all(
            color: selected ? coralOn(context) : theme.colorScheme.border,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: mono(
            context,
            size: 11,
            color: selected ? coralOn(context) : null,
          ),
        ),
      ),
    );
  }
}

