import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'chat_controller.dart';
import '../player/transcript.dart';
import 'models.dart';

/// Suggestion chips above the composer while a video plays (OTTAI-8). All act
/// locally except "More on …", which asks the assistant about the current chapter.
class QuickActions extends ConsumerWidget {
  const QuickActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final video = ref.watch(chatProvider.select((s) => s.nowPlaying));
    if (video == null) return const SizedBox.shrink();
    final chat = ref.read(chatProvider.notifier);
    final rate = ref.watch(playbackProvider.select((p) => p.rate));
    final t = ref.watch(playbackProvider.select((p) => p.t));
    final chapters = ref.watch(chaptersProvider(video.youtubeId)).value;
    final i = chapters == null ? null : chapterAt(chapters, t);
    final chapter = i == null ? null : chapters![i];
    final hasTranscript =
        ref.watch(transcriptProvider(video.youtubeId)).value != null;

    Widget chip(IconData icon, String label, VoidCallback onTap) =>
        ShadButton.outline(
          size: ShadButtonSize.sm,
          height: 30,
          leading: Icon(icon, size: 13),
          onPressed: onTap,
          child: Text(label),
        );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (t < 30) ...[
            chip(
              LucideIcons.skipForward,
              'Skip intro 30s',
              () => chat.seekTo(30),
            ),
            const SizedBox(width: 6),
          ],
          chip(LucideIcons.rotateCcw, 'Replay 10s', () => chat.back(10)),
          const SizedBox(width: 6),
          rate == 1
              ? chip(
                  LucideIcons.gauge,
                  'Slow down 0.75x',
                  () => chat.setRate(.75),
                )
              : chip(LucideIcons.gauge, 'Normal speed', () => chat.setRate(1)),
          if (hasTranscript) ...[
            const SizedBox(width: 6),
            chip(
              LucideIcons.sparkles,
              chapter != null
                  ? 'Summarize “${_short(chapter.title)}”'
                  : 'Summarize this video',
              () => chat.summarize(
                video: video,
                start: chapter?.start,
                end: chapter == null
                    ? null
                    : (i! + 1 < chapters!.length
                          ? chapters[i + 1].start
                          : null),
                label: chapter?.title ?? video.title,
              ),
            ),
          ] else if (chapter != null && chapter.title.isNotEmpty) ...[
            const SizedBox(width: 6),
            chip(
              LucideIcons.sparkles,
              'More on “${_short(chapter.title)}”',
              () => chat.send(chapter.title),
            ),
          ],
        ],
      ),
    );
  }

  static String _short(String s) =>
      s.length <= 28 ? s : '${s.substring(0, 27).trimRight()}…';
}
