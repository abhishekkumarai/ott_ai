import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../api/api.dart';
import '../auth/auth.dart';
import '../chat/chat_controller.dart';
import '../chat/models.dart';
import '../theme.dart';
import '../widgets/tappable.dart';

/// One transcript line; [start] is null for plain (untimed) text.
class TranscriptLine {
  const TranscriptLine(this.start, this.text);
  final double? start;
  final String text;

  factory TranscriptLine.fromJson(Map<String, dynamic> j) => TranscriptLine(
    (j['start_s'] as num?)?.toDouble(),
    j['text'] as String? ?? '',
  );
}

/// Admin-curated transcript (OTTAI-20); null when the video has none.
final transcriptProvider = FutureProvider.family<List<TranscriptLine>?, String>(
  (ref, youtubeId) async {
    ref.keepAlive();
    try {
      final data = await ref
          .read(apiProvider)
          .get('/videos/$youtubeId/transcript');
      final lines = [
        for (final l in data as List)
          TranscriptLine.fromJson(l as Map<String, dynamic>),
      ];
      return lines.isEmpty ? null : lines;
    } on ApiException {
      return null; // 404 = no transcript; errors just hide the feature
    }
  },
);

/// "Transcript" link, shown only when the video has one.
class TranscriptLink extends ConsumerWidget {
  const TranscriptLink({super.key, required this.video});
  final Video video;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(transcriptProvider(video.youtubeId)).value;
    if (lines == null) return const SizedBox.shrink();
    return ShadButton.link(
      size: ShadButtonSize.sm,
      padding: EdgeInsets.zero,
      height: 24,
      foregroundColor: coralOn(context),
      onPressed: () => showTranscriptSheet(context, video),
      child: const Text('Transcript'),
    );
  }
}

void showTranscriptSheet(BuildContext context, Video video) {
  final width = MediaQuery.sizeOf(context).width;
  showShadSheet(
    context: context,
    side: ShadSheetSide.right,
    builder: (ctx) => ShadSheet(
      title: const Text('Transcript'),
      description: Text(
        video.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      constraints: BoxConstraints(maxWidth: width < 520 ? width * .92 : 440),
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height - 140,
        child: _TranscriptList(video: video),
      ),
    ),
  );
}

class _TranscriptList extends ConsumerWidget {
  const _TranscriptList({required this.video});
  final Video video;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final lines =
        ref.watch(transcriptProvider(video.youtubeId)).value ?? const [];
    final playing = ref.watch(
      chatProvider.select((s) => s.nowPlaying?.youtubeId == video.youtubeId),
    );
    final t = ref.watch(playbackProvider.select((p) => p.t));
    final chat = ref.read(chatProvider.notifier);

    // The line being spoken: the last timed line at or before the playhead.
    int? current;
    if (playing) {
      for (var i = 0; i < lines.length; i++) {
        final s = lines[i].start;
        if (s != null && s <= t) current = i;
      }
    }

    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final line = lines[i];
        final start = line.start;
        final text = Text(
          line.text,
          style: theme.textTheme.small.copyWith(
            height: 1.45,
            fontWeight: i == current ? FontWeight.w600 : FontWeight.w400,
          ),
        );
        if (start == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: text,
          );
        }
        final row = Tappable(
          radius: 8,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          semanticLabel: 'Jump to ${formatTime(start)}',
          onTap: () =>
              playing ? chat.seekTo(start) : chat.play(video, start: start),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  formatTime(start),
                  style: mono(context, size: 12, color: coralOn(context)),
                ),
              ),
              Expanded(child: text),
            ],
          ),
        );
        if (i != current) return row;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: coralSoftOn(context),
            border: Border(left: BorderSide(color: coral, width: 2)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: row,
        );
      },
    );
  }
}
