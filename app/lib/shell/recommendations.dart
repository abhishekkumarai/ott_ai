import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../chat/widgets.dart';

/// "Up next" strip under the theater player: the same queue "next" plays (the live
/// reply's alternatives, then related videos).
class Recommendations extends ConsumerWidget {
  const Recommendations({super.key, this.strip = true});
  final bool strip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final s = ref.watch(chatProvider);
    final chat = ref.read(chatProvider.notifier);
    final queue = s.upNext;

    if (queue.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text(
          s.loadingRecommendations
              ? 'Finding related videos…'
              : 'No related videos yet.',
          style: theme.textTheme.muted,
        ),
      );
    }
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      itemCount: queue.length,
      separatorBuilder: (_, _) => const SizedBox(width: 2),
      itemBuilder: (_, i) => SizedBox(
        width: 176,
        child: VideoCard(video: queue[i], onTap: () => chat.play(queue[i])),
      ),
    );
  }
}
