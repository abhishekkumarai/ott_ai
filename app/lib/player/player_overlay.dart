import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../chat/models.dart';
import '../chat/widgets.dart';
import '../shell/recommendations.dart';
import '../theme.dart';
import 'player_handle.dart';

/// Covers the chat area while a video plays. Chat/voice commands keep working here.
class PlayerOverlay extends ConsumerStatefulWidget {
  const PlayerOverlay({super.key, this.inlineRecommendations = true});

  /// Show "Up next" as a strip under the player (when there is no right panel).
  final bool inlineRecommendations;

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
      if (!node.hasPrimaryFocus || e is KeyUpEvent) {
        return KeyEventResult.ignored;
      }
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
          child: _Main(
            video: video,
            composerFocus: _composerFocus,
            inlineRecommendations: widget.inlineRecommendations,
          ),
        ),
      ),
    );
  }
}

class _Main extends ConsumerWidget {
  const _Main({
    required this.video,
    required this.composerFocus,
    required this.inlineRecommendations,
  });
  final Video video;
  final FocusNode composerFocus;
  final bool inlineRecommendations;

  // Approximate fixed heights used to budget the player (see LayoutBuilder below).
  static const _controlsH = 56.0;
  static const _metaH = 52.0;

  /// Header (~34) + strip of 176px-wide cards: 16:9 thumb (≈92) + meta (≈58) + padding.
  static const _stripH = 172.0;
  static const _recsH = _stripH + 34;
  static const _composerH = 72.0;

  /// Room for the latest question + reply without clipping the question.
  static const _minTranscriptH = 96.0;

  /// Narrowest desktop column, so a short window doesn't squeeze the composer.
  static const _minColumnW = 560.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final handle = ref.read(playerHandleProvider);
    final messages = ref.watch(chatProvider.select((s) => s.messages));
    final sending = ref.watch(chatProvider.select((s) => s.sending));
    final hasError = ref.watch(playbackProvider.select((p) => p.error != null));
    final recent = messages.length > 4
        ? messages.sublist(messages.length - 4)
        : messages;

    return LayoutBuilder(
      builder: (context, c) {
        final compact = MediaQuery.sizeOf(context).width < mobileBreakpoint;
        final hPad = compact ? 12.0 : 24.0;
        final topPad = compact ? 0.0 : 16.0;
        // Drop optional sections on short screens instead of overflowing.
        final showMeta = c.maxHeight >= 420;
        final showRecs = inlineRecommendations && c.maxHeight >= 600;
        final fixed =
            topPad +
            _controlsH +
            (hasError ? 22 : 0) +
            (showMeta ? _metaH : 0) +
            (showRecs ? _recsH : 0) +
            _composerH +
            _minTranscriptH;
        final playerW = c.maxWidth - (compact ? 0 : 2 * hPad);
        final playerH = (playerW * 9 / 16).clamp(
          0.0,
          (c.maxHeight - fixed).clamp(0.0, double.infinity),
        );
        final w = playerH * 16 / 9;
        // Video, controls, title, transcript and composer share one centered
        // column so their edges line up. On phones the video is edge-to-edge
        // and the rest is inset by hPad.
        final colW = compact
            ? c.maxWidth
            : math.min(playerW, math.max(w, _minColumnW));
        final pad = compact ? hPad : 0.0;

        return SafeArea(
          top: false,
          child: Center(
            child: SizedBox(
              width: colW,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: topPad),
                  Center(
                    child: SizedBox(
                      width: w,
                      height: playerH,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(compact ? 0 : 10),
                        child: ref.read(playerViewBuilderProvider)(handle),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: pad),
                    child: const _Controls(),
                  ),
                  if (showMeta)
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad + 4, 0, pad + 4, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            video.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.large.copyWith(fontSize: 16),
                          ),
                          Text(
                            video.channel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.muted,
                          ),
                        ],
                      ),
                    ),
                  if (showRecs) ...[
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad + 4, 12, pad, 6),
                      child: Text(
                        'Up next',
                        style: theme.textTheme.small.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: _stripH,
                      child: Recommendations(strip: true),
                    ),
                  ],
                  Expanded(
                    // Fade the top edge so partially scrolled messages don't look cut off.
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (r) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0xFF000000)],
                        stops: [0, .22],
                      ).createShader(r),
                      child: ListView(
                        reverse: true,
                        padding: EdgeInsets.fromLTRB(pad + 4, 8, pad + 4, 8),
                        children: [
                          if (sending)
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: TypingIndicator(),
                            ),
                          for (final m in recent.reversed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: MessageBubble(
                                message: m,
                                showVideos: false,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(pad, 0, pad, 12),
                    child: Composer(
                      autofocus: true,
                      playerKeys: true,
                      focusNode: composerFocus,
                      hint: compact
                          ? 'Try “forward 25 sec” or “stop”'
                          : 'Say “forward 25 sec”, “pause”, “next” or “stop”',
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
            btn(
              p.playing ? LucideIcons.pause : LucideIcons.play,
              p.playing ? 'Pause  Space' : 'Play  Space',
              chat.togglePause,
            ),
            btn(
              LucideIcons.fastForward,
              'Forward 25s  →',
              () => chat.forward(seekStep),
            ),
            btn(LucideIcons.skipForward, 'Next  N', chat.next),
            const SizedBox(width: 6),
            Text(
              '${formatTime(p.t)} / ${formatTime(p.d)}',
              style: theme.textTheme.small.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: cs.mutedForeground,
              ),
              overflow: TextOverflow.fade,
              softWrap: false,
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
            if (MediaQuery.sizeOf(context).width < mobileBreakpoint)
              ShadTooltip(
                builder: (_) => const Text('Stop  Esc'),
                child: ShadIconButton.ghost(
                  icon: const Icon(LucideIcons.x, size: 18),
                  onPressed: chat.stopFromUi,
                ),
              )
            else
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
                  child: Text(
                    '${p.error!} Try another one from the list.',
                    style: theme.textTheme.small.copyWith(
                      color: cs.destructive,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
