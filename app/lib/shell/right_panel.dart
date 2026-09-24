import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import 'history.dart';
import 'recommendations.dart';

enum _Tab { upNext, history }

/// Right column: chat history, plus "Up next" recommendations while a video plays.
class RightPanel extends ConsumerStatefulWidget {
  const RightPanel({super.key});

  @override
  ConsumerState<RightPanel> createState() => _RightPanelState();
}

class _RightPanelState extends ConsumerState<RightPanel> {
  _Tab _tab = _Tab.upNext;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final playing = ref.watch(chatProvider.select((s) => s.playerOpen));

    // Each new video brings "Up next" back to the front.
    ref.listen(chatProvider.select((s) => s.nowPlaying?.youtubeId), (
      prev,
      next,
    ) {
      if (next != null && next != prev) setState(() => _tab = _Tab.upNext);
    });

    final tab = playing ? _tab : _Tab.history;

    Widget tabButton(_Tab t, String label, IconData icon) {
      final selected = tab == t;
      return Expanded(
        child: selected
            ? ShadButton.secondary(
                size: ShadButtonSize.sm,
                leading: Icon(icon, size: 14),
                onPressed: () {},
                child: Text(label),
              )
            : ShadButton.ghost(
                size: ShadButtonSize.sm,
                leading: Icon(icon, size: 14),
                foregroundColor: cs.mutedForeground,
                onPressed: () => setState(() => _tab = t),
                child: Text(label),
              ),
      );
    }

    return SafeArea(
      left: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
            child: playing
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.muted.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Row(
                        children: [
                          tabButton(
                            _Tab.upNext,
                            'Up next',
                            LucideIcons.listVideo,
                          ),
                          const SizedBox(width: 3),
                          tabButton(
                            _Tab.history,
                            'History',
                            LucideIcons.history,
                          ),
                        ],
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Text(
                      'History',
                      style: theme.textTheme.small.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
          ),
          Expanded(
            child: tab == _Tab.upNext
                ? const Recommendations()
                : const HistoryList(),
          ),
        ],
      ),
    );
  }
}
