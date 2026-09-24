import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../chat/models.dart';
import '../chat/widgets.dart';
import '../theme.dart';
import 'player_handle.dart';
import 'player_view.dart';

/// Covers the chat area while a video plays. Wide screens get a recommendations
/// side panel; phones get a stacked layout. Chat/voice commands keep working here.
class PlayerOverlay extends ConsumerStatefulWidget {
  const PlayerOverlay({super.key});

  @override
  ConsumerState<PlayerOverlay> createState() => _PlayerOverlayState();
}

class _PlayerOverlayState extends ConsumerState<PlayerOverlay> {
  final _focus = FocusNode(debugLabel: 'player-shortcuts');
  final _composerFocus = FocusNode(debugLabel: 'player-composer');
  StreamSubscription<PlayerEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(playerHandleProvider).events.listen((e) {
      if (e.type == 'refocus' && mounted) _composerFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _focus.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.read(chatProvider.notifier);
    final video = ref.watch(chatProvider.select((s) => s.nowPlaying));
    if (video == null) return const SizedBox.shrink();
    final cs = ShadTheme.of(context).colorScheme;

    // Player shortcuts only when the player area itself has focus. Keys typed in the
    // command box are never consumed here (returning `ignored` lets them through).
    KeyEventResult onKey(FocusNode node, KeyEvent e) {
      if (!node.hasPrimaryFocus || e is KeyUpEvent) return KeyEventResult.ignored;
      final action = switch (e.logicalKey) {
        LogicalKeyboardKey.arrowRight => () => chat.forward(seekStep),
        LogicalKeyboardKey.arrowLeft => () => chat.back(seekStep),
        LogicalKeyboardKey.space || LogicalKeyboardKey.keyK => chat.togglePause,
        LogicalKeyboardKey.keyN => chat.next,
        LogicalKeyboardKey.escape => chat.stopFromUi,
        _ => null,
      };
      if (action == null) return KeyEventResult.ignored;
      action();
      return KeyEventResult.handled;
    }

    return Focus(
      focusNode: _focus,
      onKeyEvent: onKey,
      child: KeyedSubtree(
        key: const ValueKey('player-overlay'),
        child: ColoredBox(
          color: cs.background,
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= wideBreakpoint;
              final main = _Main(video: video, wide: wide, composerFocus: _composerFocus);
              if (!wide) return main;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: main),
                  VerticalDivider(width: 1, color: cs.border),
                  const SizedBox(width: 360, child: _Recommendations(vertical: true)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Main extends ConsumerWidget {
  const _Main({required this.video, required this.wide, required this.composerFocus});
  final Video video;
  final bool wide;
  final FocusNode composerFocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final handle = ref.read(playerHandleProvider);
    final messages = ref.watch(chatProvider.select((s) => s.messages));
    final sending = ref.watch(chatProvider.select((s) => s.sending));
    final recent = messages.length > 4 ? messages.sublist(messages.length - 4) : messages;

    final player = LayoutBuilder(
      builder: (context, c) {
        // Keep 16:9 but never taller than ~62% of the screen so controls stay visible.
        final maxH = MediaQuery.sizeOf(context).height * (wide ? 0.62 : 0.4);
        var w = c.maxWidth;
        var h = w * 9 / 16;
        if (h > maxH) {
          h = maxH;
          w = h * 16 / 9;
        }
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(wide ? 10 : 0),
              child: PlayerView(key: const ValueKey('player'), handle: handle),
            ),
          ),
        );
      },
    );

    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: EdgeInsets.fromLTRB(wide ? 24 : 0, wide ? 20 : 0, wide ? 24 : 0, 0), child: player),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: wide ? 24 : 12),
            child: const _Controls(),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 2, wide ? 28 : 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(video.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.large.copyWith(fontSize: 16)),
                Text(video.channel, style: theme.textTheme.muted),
              ],
            ),
          ),
          if (!wide) ...[
            const SizedBox(height: 12),
            const SizedBox(height: 176, child: _Recommendations(vertical: false)),
          ],
          Expanded(
            child: ListView(
              reverse: true,
              padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 12, wide ? 28 : 16, 8),
              children: [
                if (sending) const Align(alignment: Alignment.centerLeft, child: TypingIndicator()),
                for (final m in recent.reversed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: MessageBubble(message: m, showVideos: false),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 0, wide ? 24 : 12, 12),
            child: Composer(
              autofocus: true,
              playerKeys: true,
              focusNode: composerFocus,
              hint: 'Say “forward 25 sec”, “pause”, “next” or “stop”',
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final p = ref.watch(playbackProvider);
    final chat = ref.read(chatProvider.notifier);
    final progress = p.d > 0 ? (p.t / p.d).clamp(0.0, 1.0) : 0.0;

    Widget btn(IconData icon, String tip, VoidCallback onTap) => ShadTooltip(
          builder: (_) => Text(tip),
          child: ShadIconButton.ghost(icon: Icon(icon, size: 18), onPressed: onTap),
        );

    return Column(
      children: [
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 3,
            color: accent,
            backgroundColor: cs.muted,
          ),
        ),
        Row(
          children: [
            btn(LucideIcons.rewind, 'Back 25s  ←', () => chat.back(seekStep)),
            btn(p.playing ? LucideIcons.pause : LucideIcons.play, p.playing ? 'Pause  Space' : 'Play  Space',
                chat.togglePause),
            btn(LucideIcons.fastForward, 'Forward 25s  →', () => chat.forward(seekStep)),
            btn(LucideIcons.skipForward, 'Next  N', chat.next),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${formatTime(p.t)} / ${formatTime(p.d)}',
                style: theme.textTheme.small.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: cs.mutedForeground,
                ),
                overflow: TextOverflow.fade,
                softWrap: false,
              ),
            ),
            const Spacer(),
            if (p.muted)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                leading: const Icon(LucideIcons.volumeX, size: 14),
                onPressed: chat.unmute,
                child: const Text('Unmute'),
              ),
            const SizedBox(width: 4),
            ShadButton.ghost(
              size: ShadButtonSize.sm,
              leading: const Icon(LucideIcons.x, size: 16),
              onPressed: chat.stopFromUi,
              child: const Text('Stop'),
            ),
          ],
        ),
        if (p.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text('${p.error!} Try another one from the list.',
                      style: theme.textTheme.small.copyWith(color: cs.destructive)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Recommendations extends ConsumerWidget {
  const _Recommendations({required this.vertical});
  final bool vertical;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final s = ref.watch(chatProvider);
    final chat = ref.read(chatProvider.notifier);
    final recs = s.recommendations;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(vertical ? 18 : 16, vertical ? 20 : 0, 16, 8),
      child: Text('Up next', style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600)),
    );

    if (s.loadingRecommendations && recs.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header,
        Padding(
          padding: EdgeInsets.symmetric(horizontal: vertical ? 18 : 16),
          child: Text('Finding related videos…', style: theme.textTheme.muted),
        ),
      ]);
    }
    if (recs.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header,
        Padding(
          padding: EdgeInsets.symmetric(horizontal: vertical ? 18 : 16),
          child: Text('No related videos yet.', style: theme.textTheme.muted),
        ),
      ]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        Expanded(
          child: vertical
              ? ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                  itemCount: recs.length,
                  itemBuilder: (_, i) => VideoCard(video: recs[i], compact: true, onTap: () => chat.play(recs[i])),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: recs.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 2),
                  itemBuilder: (_, i) => SizedBox(
                    width: 180,
                    child: VideoCard(video: recs[i], onTap: () => chat.play(recs[i])),
                  ),
                ),
        ),
      ],
    );
  }
}
