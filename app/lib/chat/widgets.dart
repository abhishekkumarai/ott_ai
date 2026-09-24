import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../theme.dart';
import '../voice/voice.dart';
import 'chat_controller.dart';
import 'models.dart';

/// A thumbnail card for a video result or recommendation.
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.compact = false,
    this.active = false,
  });
  final Video video;
  final VoidCallback onTap;
  final bool compact;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: cs.muted),
            Image.network(
              video.thumbnail,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  Icon(LucideIcons.clapperboard, color: cs.mutedForeground),
            ),
            if (video.durationS > 0)
              Positioned(
                right: 6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xCC000000),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    child: Text(
                      formatTime(video.durationS),
                      style: theme.textTheme.small.copyWith(
                        color: Colors.white,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.small.copyWith(
            fontWeight: FontWeight.w500,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          video.channel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.muted.copyWith(fontSize: 12),
        ),
      ],
    );
    return Semantics(
      button: true,
      label: 'Play ${video.title}',
      child: Material(
        color: active ? cs.muted : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: cs.muted.withValues(alpha: .6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: compact
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 132, child: thumb),
                      const SizedBox(width: 10),
                      Expanded(child: meta),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [thumb, const SizedBox(height: 8), meta],
                  ),
          ),
        ),
      ),
    );
  }
}

class MessageBubble extends ConsumerWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.showVideos = true,
  });
  final ChatMessage message;
  final bool showVideos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final isUser = message.role == Role.user;
    // Plain Text only: server/LLM content is never interpreted as markup.
    final text = Text(
      message.text,
      style: theme.textTheme.p.copyWith(
        color: isUser ? cs.primaryForeground : cs.foreground,
        height: 1.5,
        fontSize: 15,
      ),
    );
    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: text,
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionArea(child: text),
          if (showVideos && message.videos.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 196,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: message.videos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) => SizedBox(
                  width: 220,
                  child: VideoCard(
                    video: message.videos[i],
                    onTap: () =>
                        ref.read(chatProvider.notifier).play(message.videos[i]),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = ShadTheme.of(context).colorScheme.mutedForeground;
    return Semantics(
      label: 'Looking for videos',
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Opacity(
                  opacity:
                      0.3 + 0.7 * (1 - ((_c.value * 3 - i) % 3).clamp(0, 1)),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Text + push-to-talk input. Used in the chat and inside the player overlay.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    this.hint = 'Ask for a video on any topic…',
    this.autofocus = false,
    this.focusNode,
    this.playerKeys = false,
  });
  final String hint;
  final bool autofocus;
  final FocusNode? focusNode;

  /// While a video plays: ← / → seek and Esc stops when the box is empty.
  final bool playerKeys;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _text = TextEditingController();
  late final FocusNode _focus = (widget.focusNode ?? FocusNode())
    ..onKeyEvent = _onKey;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!widget.playerKeys || e is KeyUpEvent) return KeyEventResult.ignored;
    final chat = ref.read(chatProvider.notifier);
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      chat.stopFromUi();
      return KeyEventResult.handled;
    }
    if (_text.text.isNotEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowRight) {
      chat.forward(seekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      chat.back(seekStep);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _text.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _send([String? value, bool fromVoice = false]) {
    final text = (value ?? _text.text).trim();
    if (text.isEmpty) return;
    ref.read(chatProvider.notifier).send(text);
    _text.clear();
    // Keep typing commands without re-clicking the box (submit unfocuses on web).
    if (!fromVoice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  void _toggleMic() {
    final voice = ref.read(voiceProvider.notifier);
    if (ref.read(voiceProvider).listening) {
      voice.stop();
    } else {
      voice.start((text) => _send(text, true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final sending = ref.watch(chatProvider.select((s) => s.sending));
    final voice = ref.watch(voiceProvider);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.background,
        border: Border.all(color: voice.listening ? cs.ring : cs.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
        child: Row(
          children: [
            Expanded(
              child: voice.listening
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Text(
                        voice.partial.isEmpty ? 'Listening…' : voice.partial,
                        style: theme.textTheme.p.copyWith(
                          color: cs.mutedForeground,
                          fontSize: 15,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  : ShadInput(
                      controller: _text,
                      focusNode: _focus,
                      autofocus: widget.autofocus,
                      placeholder: Text(
                        widget.hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      decoration: const ShadDecoration(
                        border: ShadBorder.none,
                        focusedBorder: ShadBorder.none,
                        secondaryFocusedBorder: ShadBorder.none,
                      ),
                      maxLength: 500,
                      maxLengthEnforcement: MaxLengthEnforcement.enforced,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _send,
                    ),
            ),
            if (voice.available)
              ShadIconButton.ghost(
                icon: Icon(
                  voice.listening ? LucideIcons.micOff : LucideIcons.mic,
                  size: 18,
                ),
                onPressed: _toggleMic,
                foregroundColor: voice.listening ? accent : null,
              ),
            const SizedBox(width: 2),
            ShadIconButton(
              width: 34,
              height: 34,
              icon: sending
                  ? SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.primaryForeground,
                      ),
                    )
                  : const Icon(LucideIcons.arrowUp, size: 18),
              onPressed: sending ? null : _send,
            ),
          ],
        ),
      ),
    );
  }
}
