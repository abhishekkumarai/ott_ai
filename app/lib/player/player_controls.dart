import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../chat/models.dart';
import '../theme.dart';

/// Scrub bar: follows playback, seeks on release (OTTAI-3).
class ScrubBar extends ConsumerStatefulWidget {
  const ScrubBar({super.key});

  @override
  ConsumerState<ScrubBar> createState() => _ScrubBarState();
}

class _ScrubBarState extends ConsumerState<ScrubBar> {
  final _c = ShadSliderController(initialValue: 0);
  bool _dragging = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(playbackProvider);
    final max = p.d > 0 ? p.d : 1.0;
    if (!_dragging) _c.value = p.t.clamp(0, max).toDouble();
    return SizedBox(
      height: 18,
      child: ShadSlider(
        controller: _c,
        min: 0,
        max: max,
        trackHeight: 4,
        thumbRadius: 6,
        activeTrackColor: coral,
        thumbColor: coral,
        thumbBorderColor: coral,
        semanticFormatterCallback: (v) => formatTime(v),
        onChangeStart: (_) => _dragging = true,
        onChangeEnd: (v) {
          _dragging = false;
          ref.read(chatProvider.notifier).seekTo(v);
        },
      ),
    );
  }
}

/// Mute toggle + volume slider.
class VolumeControl extends ConsumerStatefulWidget {
  const VolumeControl({super.key, this.width = 84});
  final double width;

  @override
  ConsumerState<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<VolumeControl> {
  final _c = ShadSliderController(initialValue: 100);
  bool _dragging = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(playbackProvider);
    final chat = ref.read(chatProvider.notifier);
    final level = p.muted ? 0.0 : p.volume.clamp(0, 100).toDouble();
    if (!_dragging) _c.value = level;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShadTooltip(
          builder: (_) => Text(p.muted ? 'Unmute  M' : 'Mute  M'),
          child: ShadIconButton.ghost(
            width: 32,
            height: 32,
            icon: Icon(
              level == 0 ? LucideIcons.volumeX : LucideIcons.volume2,
              size: 16,
            ),
            onPressed: chat.toggleMute,
          ),
        ),
        SizedBox(
          width: widget.width,
          child: ShadSlider(
            controller: _c,
            min: 0,
            max: 100,
            trackHeight: 3,
            thumbRadius: 5,
            semanticFormatterCallback: (v) => 'Volume ${v.round()}',
            onChangeStart: (_) => _dragging = true,
            onChanged: chat.setVolume,
            onChangeEnd: (v) {
              _dragging = false;
              chat.setVolume(v);
            },
          ),
        ),
      ],
    );
  }
}

/// Round coral play/pause.
class PlayPauseButton extends ConsumerWidget {
  const PlayPauseButton({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playbackProvider.select((p) => p.playing));
    return ShadTooltip(
      builder: (_) => Text(playing ? 'Pause  Space' : 'Play  Space'),
      child: ShadIconButton(
        width: size,
        height: size,
        decoration: ShadDecoration(
          border: ShadBorder.all(radius: BorderRadius.circular(999)),
        ),
        icon: Icon(
          playing ? LucideIcons.pause : LucideIcons.play,
          size: size * .42,
        ),
        onPressed: ref.read(chatProvider.notifier).togglePause,
      ),
    );
  }
}

/// Small ghost control with a tooltip.
Widget controlButton(
  IconData icon,
  String tip,
  VoidCallback? onTap, {
  double size = 32,
  Color? color,
}) => ShadTooltip(
  builder: (_) => Text(tip),
  child: ShadIconButton.ghost(
    width: size,
    height: size,
    foregroundColor: color,
    icon: Icon(icon, size: 16),
    onPressed: onTap,
  ),
);
