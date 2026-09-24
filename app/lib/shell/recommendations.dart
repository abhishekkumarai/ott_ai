import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../chat/widgets.dart';

/// "Up next" recommendations for the playing video.
///
/// [strip] = a single horizontally scrolling row (under the player on narrow screens);
/// otherwise a vertical list of horizontal cards (thumbnail beside the text) for the
/// right panel.
class Recommendations extends ConsumerWidget {
  const Recommendations({super.key, this.strip = false});
  final bool strip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final s = ref.watch(chatProvider);
    final chat = ref.read(chatProvider.notifier);
    final recs = s.recommendations;
    final pad = EdgeInsets.symmetric(horizontal: strip ? 16 : 20);

    if (recs.isEmpty) {
      return Padding(
        padding: pad.copyWith(top: 4),
        child: Text(
          s.loadingRecommendations
              ? 'Finding related videos…'
              : 'No related videos yet.',
          style: theme.textTheme.muted,
        ),
      );
    }

    if (strip) {
      return ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemCount: recs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 2),
        itemBuilder: (_, i) => SizedBox(
          width: 176,
          child: VideoCard(video: recs[i], onTap: () => chat.play(recs[i])),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
      itemCount: recs.length,
      itemBuilder: (_, i) => VideoCard(
        video: recs[i],
        compact: true,
        onTap: () => chat.play(recs[i]),
      ),
    );
  }
}
