import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../chat/models.dart';
import '../library/saved.dart';
import '../settings/preferences.dart';
import '../theme.dart';
import 'player_controls.dart';
import 'transcript.dart';

/// Keeps the video playing while the chat is in front (OTTAI-3).
///
/// [docked] (desktop): at the top of the Recommended rail (OTTAI-23).
/// [compact] (phones): a strip, small video on the left, title and controls on
/// the right. Otherwise (tablets) a ~420px floating card, top-right.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key, this.compact = false, this.docked = false});
  final bool compact;
  final bool docked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final video = ref.watch(chatProvider.select((s) => s.nowPlaying));
    if (video == null) return const SizedBox.shrink();
    final view = ref.read(playerViewBuilderProvider)(
      ref.read(playerHandleProvider),
    );

    return ShadCard(
      key: const ValueKey('mini-player'),
      padding: EdgeInsets.zero,
      radius: BorderRadius.circular(docked ? 16 : 18),
      clipBehavior: Clip.antiAlias,
      shadows: docked
          ? const []
          : const [
              BoxShadow(
                color: Color(0x2E000000),
                blurRadius: 32,
                offset: Offset(0, 12),
              ),
            ],
      child: compact
          ? _strip(context, video, view)
          : _card(context, video, view),
    );
  }

  Widget _card(BuildContext context, Video video, Widget view) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Expanded(child: _Label(video: video)),
            const _QualityPill(),
            SaveButton(video: video, iconOnly: true),
            const _WindowButtons(),
          ],
        ),
      ),
      AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            view,
            const Positioned(left: 8, bottom: 8, child: _TimeBadge()),
            const Positioned(right: 8, top: 8, child: _LoopBadge()),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(10, 8, 10, 0),
        child: ScrubBar(),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
        child: Consumer(
          builder: (context, ref, _) {
            final chat = ref.read(chatProvider.notifier);
            final captions = ref.watch(
              playbackProvider.select((p) => p.captions),
            );
            return Row(
              children: [
                controlButton(
                  LucideIcons.rewind,
                  'Back ${seekStep.round()}s  ←',
                  () => chat.back(seekStep),
                ),
                const SizedBox(width: 2),
                const PlayPauseButton(size: 38),
                const SizedBox(width: 2),
                controlButton(
                  LucideIcons.fastForward,
                  'Forward ${seekStep.round()}s  →',
                  () => chat.forward(seekStep),
                ),
                controlButton(LucideIcons.skipForward, 'Next  N', chat.next),
                const Spacer(),
                const VolumeControl(width: 72),
                controlButton(
                  LucideIcons.captions,
                  captions ? 'Captions off' : 'Captions on',
                  chat.toggleCaptions,
                  color: captions ? coral : null,
                ),
              ],
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Row(
          children: [
            Expanded(child: _Title(video: video)),
            TranscriptLink(video: video),
          ],
        ),
      ),
    ],
  );

  Widget _strip(BuildContext context, Video video, Widget view) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(width: 144, height: 81, child: view),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Title(video: video, maxLines: 2),
                  const SizedBox(height: 4),
                  Consumer(
                    builder: (context, ref, _) {
                      final chat = ref.read(chatProvider.notifier);
                      return Row(
                        children: [
                          const PlayPauseButton(size: 32),
                          const SizedBox(width: 4),
                          controlButton(
                            LucideIcons.skipForward,
                            'Next',
                            chat.next,
                            size: 30,
                          ),
                          const SizedBox(width: 4),
                          const Flexible(child: _TimeText()),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            const _WindowButtons(vertical: true),
          ],
        ),
      ),
      const _Progress(),
    ],
  );
}

class _Label extends StatelessWidget {
  const _Label({required this.video});
  final Video video;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(color: coral, shape: BoxShape.circle),
          child: SizedBox.square(dimension: 7),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'Now streaming · ${video.channel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.small.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _QualityPill extends ConsumerWidget {
  const _QualityPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(playbackProvider.select((p) => p.quality));
    if (q.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: ShadBadge.outline(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
        child: Text(q, style: mono(context, size: 11)),
      ),
    );
  }
}

class _TimeBadge extends ConsumerWidget {
  const _TimeBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playbackProvider);
    final q = p.quality.isEmpty ? '' : ' • ${p.quality}';
    return IgnorePointer(
      child: ShadBadge.raw(
        variant: ShadBadgeVariant.primary,
        backgroundColor: const Color(0xB31A1C1B),
        hoverBackgroundColor: const Color(0xB31A1C1B),
        foregroundColor: const Color(0xFFFFFFFF),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        child: Text(
          '${formatTime(p.t)} / ${formatTime(p.d)}$q',
          style: mono(context, size: 11, color: const Color(0xFFFFFFFF)),
        ),
      ),
    );
  }
}

class _LoopBadge extends ConsumerWidget {
  const _LoopBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playbackProvider);
    if (!p.looping) return const SizedBox.shrink();
    return ShadBadge.raw(
      variant: ShadBadgeVariant.primary,
      backgroundColor: coral,
      hoverBackgroundColor: coral,
      foregroundColor: const Color(0xFFFFFFFF),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      onPressed: ref.read(chatProvider.notifier).unloop,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.repeat, size: 11, color: Color(0xFFFFFFFF)),
          const SizedBox(width: 4),
          Text(
            '${formatTime(p.loopStart!)}–${formatTime(p.loopEnd!)}',
            style: mono(context, size: 11, color: const Color(0xFFFFFFFF)),
          ),
        ],
      ),
    );
  }
}

class _TimeText extends ConsumerWidget {
  const _TimeText();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playbackProvider);
    return Text(
      '${formatTime(p.t)} / ${formatTime(p.d)}',
      overflow: TextOverflow.fade,
      softWrap: false,
      style: mono(context, size: 11),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.video, this.maxLines = 1});
  final Video video;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
    video.title,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    style: ShadTheme.of(
      context,
    ).textTheme.small.copyWith(fontWeight: FontWeight.w600, height: 1.35),
  );
}

/// Theater mode, or stop.
class _WindowButtons extends ConsumerWidget {
  const _WindowButtons({this.vertical = false});
  final bool vertical;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buttons = [
      if (canFullscreen && !vertical)
        controlButton(
          LucideIcons.fullscreen,
          'Fullscreen  F',
          ref.read(chatProvider.notifier).fullscreen,
        ),
      controlButton(
        LucideIcons.maximize2,
        'Theater mode  T',
        () => ref.read(playerModeProvider.notifier).set(PlayerMode.theater),
      ),
      controlButton(
        LucideIcons.x,
        'Stop  Esc',
        ref.read(chatProvider.notifier).stopFromUi,
      ),
    ];
    return vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: buttons)
        : Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }
}

class _Progress extends ConsumerWidget {
  const _Progress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playbackProvider);
    return ShadProgress(
      value: p.d > 0 ? (p.t / p.d).clamp(0.0, 1.0) : 0,
      minHeight: 3,
      color: coral,
      borderRadius: BorderRadius.zero,
      innerBorderRadius: BorderRadius.zero,
    );
  }
}
