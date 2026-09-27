import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../library/saved.dart';
import '../settings/preferences.dart';
import '../shell/recommended_rail.dart';
import '../theme.dart';
import '../widgets/tappable.dart';
import 'chat_controller.dart';
import 'models.dart';
import 'widgets.dart';

/// Product name shown on assistant replies.
const assistantName = 'OTT-AI Assistant';

/// One assistant turn: header, reply text, and — when it found videos — the main
/// video card and its key moments. Its recommendations are in the rail
/// (desktop/tablet, OTTAI-23) or a "Recommended" block (phones, OTTAI-24).
class AssistantReply extends ConsumerWidget {
  const AssistantReply({super.key, required this.message, required this.index});
  final ChatMessage message;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final main = message.videos.firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(message: message),
        const SizedBox(height: 8),
        SelectionArea(
          child: HighlightedText(
            message.text,
            message.highlights,
            style: theme.textTheme.p.copyWith(height: 1.55, fontSize: 15),
          ),
        ),
        if (main != null) ...[
          const SizedBox(height: 14),
          MainVideoCard(video: main),
          KeyMoments(video: main, replyIndex: index),
          if (MediaQuery.sizeOf(context).width < mobileBreakpoint)
            ReplyRecommendations(replyIndex: index)
          else
            _ShowRecommendations(replyIndex: index),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final ms = message.latencyMs;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ShadAvatar(
          null,
          size: const Size.square(26),
          backgroundColor: coral,
          placeholder: const Icon(
            LucideIcons.sparkles,
            size: 14,
            color: Color(0xFFFFFFFF),
          ),
        ),
        Text(
          assistantName,
          style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
        ),
        if (ms != null)
          ShadBadge.raw(
            variant: ShadBadgeVariant.primary,
            backgroundColor: successSoft,
            hoverBackgroundColor: successSoft,
            foregroundColor: success,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            child: Text(
              'Matched in ${(ms / 1000).toStringAsFixed(1)}s',
              style: mono(context, size: 11, color: success),
            ),
          ),
        if (!message.command) _Usage(message: message),
        if (message.source != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                message.source == VideoSource.catalog
                    ? LucideIcons.badgeCheck
                    : LucideIcons.search,
                size: 13,
                color: theme.colorScheme.mutedForeground,
              ),
              const SizedBox(width: 4),
              Text(
                message.source == VideoSource.catalog
                    ? 'Curated catalog'
                    : 'YouTube search',
                style: theme.textTheme.muted.copyWith(fontSize: 12),
              ),
            ],
          ),
      ],
    );
  }
}

/// "llama3.2:3b · 412 tok", or "no LLM" for keyword-fallback replies (OTTAI-27).
class _Usage extends StatelessWidget {
  const _Usage({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final model = message.model;
    final label = model == null
        ? 'no LLM'
        : '$model · ${compactTokens(message.tokens)} tok';
    return ShadTooltip(
      builder: (_) => Text(
        model == null
            ? 'Answered by keyword search; no model tokens used'
            : '${message.promptTokens} prompt + ${message.outputTokens} output tokens',
      ),
      child: Text(label, style: mono(context, size: 11)),
    );
  }
}

/// Earlier replies (desktop/tablet): "Show recommendations" loads theirs into the
/// rail; on tablets it also opens the rail sheet.
class _ShowRecommendations extends ConsumerWidget {
  const _ShowRecommendations({required this.replyIndex});
  final int replyIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(chatProvider.select((s) => s.latestReplyIndex));
    final shown = ref.watch(chatProvider.select((s) => s.railIndex));
    if (replyIndex == latest) return const SizedBox.shrink();
    final sheet = MediaQuery.sizeOf(context).width < railBreakpoint;
    if (shown == replyIndex && !sheet) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, left: 4),
        child: Row(
          children: [
            Icon(LucideIcons.panelRight, size: 14, color: coralOn(context)),
            const SizedBox(width: 6),
            Text(
              'Shown in Recommended',
              style: ShadTheme.of(
                context,
              ).textTheme.small.copyWith(color: coralOn(context)),
            ),
          ],
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: ShadButton.link(
          size: ShadButtonSize.sm,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          foregroundColor: coralOn(context),
          leading: const Icon(LucideIcons.panelRight, size: 14),
          onPressed: () {
            ref.read(chatProvider.notifier).showRecommendationsFor(replyIndex);
            if (sheet) showRecommendedSheet(context);
          },
          child: const Text('Show recommendations'),
        ),
      ),
    );
  }
}

/// The reply's top video: large thumbnail, live status, and actions.
class MainVideoCard extends ConsumerWidget {
  const MainVideoCard({super.key, required this.video});
  final Video video;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final chat = ref.read(chatProvider.notifier);
    final playing = ref.watch(
      chatProvider.select((s) => s.nowPlaying?.youtubeId == video.youtubeId),
    );
    final mode = ref.watch(playerModeProvider);

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (playing) _LiveStatus(mode: mode) else const SizedBox.shrink(),
        if (playing) const SizedBox(height: 6),
        Text(
          video.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.large.copyWith(
            fontSize: 17,
            height: 1.3,
            fontWeight: FontWeight.w700,
            letterSpacing: -.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          video.channel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.muted.copyWith(fontSize: 13),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SaveButton(video: video),
            if (!playing)
              ShadButton(
                size: ShadButtonSize.sm,
                leading: const Icon(LucideIcons.play, size: 14),
                onPressed: () => chat.play(video),
                child: const Text('Play'),
              )
            else ...[
              ShadButton.outline(
                size: ShadButtonSize.sm,
                leading: Icon(
                  mode == PlayerMode.mini
                      ? LucideIcons.maximize2
                      : LucideIcons.pictureInPicture2,
                  size: 14,
                ),
                onPressed: ref.read(playerModeProvider.notifier).toggle,
                child: Text(
                  mode == PlayerMode.mini ? 'Theater mode' : 'Mini player',
                ),
              ),
              const LoopButton(),
            ],
          ],
        ),
      ],
    );

    return ShadCard(
      padding: const EdgeInsets.all(12),
      radius: BorderRadius.circular(16),
      child: LayoutBuilder(
        builder: (context, c) {
          final thumb = Tappable(
            onTap: playing ? null : () => chat.play(video),
            radius: 10,
            semanticLabel: 'Play ${video.title}',
            child: Stack(
              children: [
                Thumbnail(video: video),
                if (!playing)
                  const Positioned.fill(child: Center(child: _PlayDisc())),
              ],
            ),
          );
          if (c.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [thumb, const SizedBox(height: 12), info],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: math.min(300, c.maxWidth * .45), child: thumb),
              const SizedBox(width: 16),
              Expanded(child: info),
            ],
          );
        },
      ),
    );
  }
}

class _PlayDisc extends StatelessWidget {
  const _PlayDisc();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(color: coral, shape: BoxShape.circle),
    child: Padding(
      padding: EdgeInsets.all(12),
      child: Icon(LucideIcons.play, size: 20, color: Color(0xFFFFFFFF)),
    ),
  );
}

class _LiveStatus extends ConsumerWidget {
  const _LiveStatus({required this.mode});
  final PlayerMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playbackProvider);
    final where = mode == PlayerMode.mini ? 'MINI-PLAYER' : 'THEATER';
    return ShadBadge.raw(
      variant: ShadBadgeVariant.primary,
      backgroundColor: coralSoftOn(context),
      hoverBackgroundColor: coralSoftOn(context),
      foregroundColor: coralOn(context),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Dot(),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'NOW PLAYING IN $where · ${formatTime(p.t)} / ${formatTime(p.d)}',
              overflow: TextOverflow.fade,
              softWrap: false,
              style: mono(context, size: 11, color: coralOn(context)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(color: coral, shape: BoxShape.circle),
    child: SizedBox.square(dimension: 7),
  );
}

/// "Loop this part" / "Stop loop 3:40–5:10" (OTTAI-13).
class LoopButton extends ConsumerWidget {
  const LoopButton({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playbackProvider);
    final chat = ref.read(chatProvider.notifier);
    if (p.looping) {
      final label =
          'Stop loop ${formatTime(p.loopStart!)}–${formatTime(p.loopEnd!)}';
      return ShadButton.outline(
        size: ShadButtonSize.sm,
        foregroundColor: coralOn(context),
        leading: const Icon(LucideIcons.repeat, size: 14),
        onPressed: chat.unloop,
        child: Text(compact ? 'Stop loop' : label),
      );
    }
    return ShadButton.outline(
      size: ShadButtonSize.sm,
      leading: const Icon(LucideIcons.repeat, size: 14),
      onPressed: chat.loopCurrentPart,
      child: const Text('Loop this part'),
    );
  }
}

// ------------------------------------------------------------------ collapsible

/// A block that folds to one line (OTTAI-6/7). Blocks start closed (the header
/// still shows a summary); a block the user opens or closes stays that way, also
/// across restarts (OTTAI-18).
class CollapsibleBlock extends ConsumerStatefulWidget {
  const CollapsibleBlock({
    super.key,
    required this.stateKey,
    required this.defaultOpen,
    required this.title,
    required this.child,
  });
  final String stateKey;
  final bool defaultOpen;
  final Widget title;
  final Widget child;

  @override
  ConsumerState<CollapsibleBlock> createState() => _CollapsibleBlockState();
}

class _CollapsibleBlockState extends ConsumerState<CollapsibleBlock> {
  static const _item = 'block';
  late final ShadAccordionController<String> _c;

  bool get _open =>
      ref.read(collapseProvider)[widget.stateKey] ?? widget.defaultOpen;

  @override
  void initState() {
    super.initState();
    _c = ShadAccordionController<String>(_open ? _item : null);
    _c.addListener(_onToggle);
  }

  void _onToggle() {
    final open = _c.value.contains(_item);
    if (open != _open) {
      ref.read(collapseProvider.notifier).set(widget.stateKey, open);
    }
  }

  /// Brings the accordion in line with the stored/default state without
  /// recording it as a user toggle.
  void _sync() {
    final want = _open;
    if (want != _c.value.contains(_item)) {
      _c.removeListener(_onToggle);
      _c.value = want ? [_item] : [];
      _c.addListener(_onToggle);
    }
  }

  @override
  void didUpdateWidget(CollapsibleBlock old) {
    super.didUpdateWidget(old);
    // Follow the default (e.g. auto-collapse when a newer reply arrives) unless
    // the user has toggled this block.
    _sync();
  }

  @override
  void dispose() {
    _c.removeListener(_onToggle);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Saved toggles load asynchronously (OTTAI-18); apply them when they arrive.
    ref.listen(
      collapseProvider.select((m) => m[widget.stateKey]),
      (_, _) => _sync(),
    );
    final cs = ShadTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.card,
          border: Border.all(color: cs.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: ShadAccordion<String>(
          controller: _c,
          children: [
            ShadAccordionItem<String>(
              value: _item,
              separator: const SizedBox.shrink(),
              underlineTitleOnHover: false,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              title: widget.title,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _blockKey(WidgetRef ref, int replyIndex, String kind) =>
    '${ref.read(chatProvider).conversationId ?? 'new'}:$replyIndex:$kind';

// ------------------------------------------------------------------ key moments

/// Chapter list: click to seek, current chapter highlighted (OTTAI-6).
class KeyMoments extends ConsumerWidget {
  const KeyMoments({super.key, required this.video, required this.replyIndex});
  final Video video;
  final int replyIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapters = ref.watch(chaptersProvider(video.youtubeId)).value;
    if (chapters == null || chapters.isEmpty) return const SizedBox.shrink();
    final theme = ShadTheme.of(context);
    final playing = ref.watch(
      chatProvider.select((s) => s.nowPlaying?.youtubeId == video.youtubeId),
    );
    final t = ref.watch(playbackProvider.select((p) => p.t));
    final current = playing ? chapterAt(chapters, t) : null;
    final chat = ref.read(chatProvider.notifier);

    return CollapsibleBlock(
      stateKey: _blockKey(ref, replyIndex, 'moments'),
      defaultOpen: false,
      title: Row(
        children: [
          Icon(LucideIcons.listVideo, size: 15, color: coralOn(context)),
          const SizedBox(width: 8),
          Text(
            'Key moments',
            style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              current != null
                  ? 'Now: ${formatTime(chapters[current].start)} ${chapters[current].title}'
                  : '${chapters.length} chapters · click to seek',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.muted.copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
      child: Column(
        children: [
          for (var i = 0; i < chapters.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _ChapterRow(
                chapter: chapters[i],
                current: i == current,
                onTap: () => playing
                    ? chat.seekTo(chapters[i].start)
                    : chat.play(video, start: chapters[i].start),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.current,
    required this.onTap,
  });
  final Chapter chapter;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final row = Tappable(
      onTap: onTap,
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      semanticLabel: 'Jump to ${formatTime(chapter.start)} ${chapter.title}',
      child: Row(
        children: [
          ShadBadge.raw(
            variant: ShadBadgeVariant.primary,
            backgroundColor: current ? coral : cs.muted,
            hoverBackgroundColor: current ? coral : cs.muted,
            foregroundColor: current ? const Color(0xFFFFFFFF) : cs.foreground,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            child: Text(
              formatTime(chapter.start),
              style: mono(
                context,
                size: 12,
                color: current ? const Color(0xFFFFFFFF) : coralOn(context),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              chapter.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.small.copyWith(
                fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (current) ...[
            ShadBadge.raw(
              variant: ShadBadgeVariant.outline,
              foregroundColor: coralOn(context),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
              child: Text(
                'PLAYING NOW',
                style: mono(context, size: 10, color: coralOn(context)),
              ),
            ),
            const SizedBox(width: 6),
            Icon(LucideIcons.audioLines, size: 16, color: coral),
          ] else
            Icon(LucideIcons.play, size: 14, color: cs.mutedForeground),
        ],
      ),
    );
    if (!current) return row;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: coralSoftOn(context),
        border: Border.all(color: coralSoftBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: row,
    );
  }
}

// ------------------------------------------------------------------ recommended (phones)

/// Phones: the reply's recommendations as an in-chat block that starts closed
/// (desktop and tablet show them in the rail instead, OTTAI-24).
class ReplyRecommendations extends ConsumerStatefulWidget {
  const ReplyRecommendations({super.key, required this.replyIndex});
  final int replyIndex;

  @override
  ConsumerState<ReplyRecommendations> createState() =>
      _ReplyRecommendationsState();
}

class _ReplyRecommendationsState extends ConsumerState<ReplyRecommendations> {
  bool _all = false;

  @override
  void initState() {
    super.initState();
    // Older replies have no stored list: look it up once.
    Future.microtask(() {
      if (mounted) {
        ref
            .read(chatProvider.notifier)
            .ensureRecommendations(widget.replyIndex);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final s = ref.watch(chatProvider);
    if (widget.replyIndex >= s.messages.length) return const SizedBox.shrink();
    final all = s.recommendationsFor(widget.replyIndex);
    final loading = s.loadingFor(widget.replyIndex);
    if (all.isEmpty && !loading) return const SizedBox.shrink();
    final chat = ref.read(chatProvider.notifier);
    final shown = _all ? all : all.take(3).toList();

    return CollapsibleBlock(
      stateKey: _blockKey(ref, widget.replyIndex, 'recommended'),
      defaultOpen: false,
      title: Row(
        children: [
          Icon(LucideIcons.sparkles, size: 15, color: coralOn(context)),
          const SizedBox(width: 8),
          Text(
            'Recommended',
            style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Text(
            loading ? 'finding…' : '${all.length} videos',
            style: theme.textTheme.muted.copyWith(fontSize: 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final v in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: RailRow(
                video: v,
                playing: s.nowPlaying?.youtubeId == v.youtubeId,
                watched:
                    s.nowPlaying?.youtubeId != v.youtubeId &&
                    s.played.contains(v.youtubeId),
                onTap: () => chat.play(v),
              ),
            ),
          if (all.length > 3)
            Align(
              alignment: Alignment.centerRight,
              child: ShadButton.link(
                size: ShadButtonSize.sm,
                onPressed: () => setState(() => _all = !_all),
                child: Text(_all ? 'Show fewer' : 'View all ${all.length}'),
              ),
            ),
        ],
      ),
    );
  }
}
