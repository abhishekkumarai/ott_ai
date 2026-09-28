import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../settings/preferences.dart';
import '../theme.dart';
import '../voice/voice.dart';
import '../widgets/tappable.dart';
import 'chat_controller.dart';
import 'models.dart';

/// Green "98% match" pill.
class MatchBadge extends StatelessWidget {
  const MatchBadge(this.percent, {super.key});
  final int percent;

  @override
  Widget build(BuildContext context) => ShadBadge.raw(
    variant: ShadBadgeVariant.primary,
    backgroundColor: successSoft,
    hoverBackgroundColor: successSoft,
    foregroundColor: success,
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    child: Text(
      '$percent% match',
      style: mono(context, size: 11, color: success),
    ),
  );
}

/// Dark duration chip over a thumbnail.
class DurationBadge extends StatelessWidget {
  const DurationBadge(this.seconds, {super.key});
  final int seconds;

  @override
  Widget build(BuildContext context) => ShadBadge.raw(
    variant: ShadBadgeVariant.primary,
    backgroundColor: const Color(0xD91A1C1B),
    hoverBackgroundColor: const Color(0xD91A1C1B),
    foregroundColor: const Color(0xFFFFFFFF),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
    child: Text(
      formatTime(seconds),
      style: mono(context, size: 11, color: const Color(0xFFFFFFFF)),
    ),
  );
}

/// Badge for Vidy media items indicating format / season / episode (e.g. "MOVIE", "S1 E1", "EP 1").
class ProviderBadge extends StatelessWidget {
  const ProviderBadge({super.key, required this.video});
  final Video video;

  @override
  Widget build(BuildContext context) {
    String label;
    if (video.mediaType == 'tv' &&
        video.season != null &&
        video.episode != null) {
      label = 'S${video.season} E${video.episode}';
    } else if (video.mediaType == 'anime' && video.episode != null) {
      label = 'EP ${video.episode}';
    } else if (video.mediaType == 'movie') {
      label = 'MOVIE';
    } else {
      label = video.mediaType.toUpperCase();
    }

    return ShadBadge.raw(
      variant: ShadBadgeVariant.primary,
      backgroundColor: const Color(0xD9FF5A3D),
      hoverBackgroundColor: const Color(0xD9FF5A3D),
      foregroundColor: const Color(0xFFFFFFFF),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
      child: Text(
        label,
        style: mono(context, size: 10, color: const Color(0xFFFFFFFF)),
      ),
    );
  }
}

class Thumbnail extends StatelessWidget {
  const Thumbnail({
    super.key,
    required this.video,
    this.radius = 10,
    this.showMatch = true,
  });
  final Video video;
  final double radius;

  /// Off where the match badge sits next to the thumbnail instead (rail rows).
  final bool showMatch;

  @override
  Widget build(BuildContext context) {
    final cs = ShadTheme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
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
            if (showMatch && video.match != null)
              Positioned(left: 6, top: 6, child: MatchBadge(video.match!)),
            if (showMatch && video.provider == 'vidy')
              Positioned(
                left: 6,
                bottom: 6,
                child: ProviderBadge(video: video),
              ),
            if (video.durationS > 0)
              Positioned(
                right: 6,
                bottom: 6,
                child: DurationBadge(video.durationS),
              ),
          ],
        ),
      ),
    );
  }
}

/// A thumbnail card for a search result or recommendation.
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
    final thumb = Thumbnail(video: video, radius: 8);
    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.small.copyWith(
            fontWeight: FontWeight.w600,
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
    return Tappable(
      onTap: onTap,
      selected: active,
      padding: const EdgeInsets.all(6),
      semanticLabel: 'Play ${video.title}',
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
    );
  }
}

/// Reply text with the server-chosen key phrases in coral. Plain text only:
/// server/LLM content is never interpreted as markup.
class HighlightedText extends StatelessWidget {
  const HighlightedText(this.text, this.highlights, {super.key, this.style});
  final String text;
  final List<String> highlights;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final phrases = [
      for (final h in highlights)
        if (h.trim().isNotEmpty) RegExp.escape(h),
    ];
    if (phrases.isEmpty) return Text(text, style: style);
    // Match on the original string (no toLowerCase copy, whose length can
    // differ), so the offsets always point into [text].
    final pattern = RegExp(phrases.join('|'), caseSensitive: false);
    final spans = <TextSpan>[];
    var i = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.end == m.start) continue;
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      spans.add(
        TextSpan(
          text: m[0],
          style: TextStyle(
            color: coralOn(context),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return Text.rich(TextSpan(children: spans), style: style);
  }
}

class UserBubble extends StatelessWidget {
  const UserBubble({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DecoratedBox(
          // Filled soft coral so the user's turn stands out from the page
          // background (a white card on off-white barely read as a bubble).
          decoration: BoxDecoration(
            color: coralSoftOn(context),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(6),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: SelectableText(
              message.text,
              style: theme.textTheme.p.copyWith(
                color: cs.foreground,
                height: 1.5,
                fontSize: 15,
              ),
            ),
          ),
        ),
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
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox.square(dimension: 6),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Text + push-to-talk input: a floating pill. Used in the chat and in theater mode.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    this.hint = 'Ask anything or say “skip ahead”…',
    this.autofocus = false,
    this.focusNode,
    this.playerKeys = false,
    this.footer,
  });
  final String hint;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Shown inside the box, under the input (the chat's model/context/tokens).
  final Widget? footer;

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
      voice.start(
        (text) => _send(text, true),
        localeId: ref.read(preferencesProvider).voiceLanguage,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final sending = ref.watch(chatProvider.select((s) => s.sending));
    final voice = ref.watch(voiceProvider);
    final voiceOn = ref.watch(
      preferencesProvider.select((p) => p.voiceEnabled),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.card,
        border: Border.all(color: voice.listening ? coral : cs.border),
        borderRadius: BorderRadius.circular(widget.footer == null ? 28 : 22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _input(context, theme, cs, sending, voice, voiceOn),
          if (widget.footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: widget.footer,
            ),
        ],
      ),
    );
  }

  Widget _input(
    BuildContext context,
    ShadThemeData theme,
    ShadColorScheme cs,
    bool sending,
    VoiceState voice,
    bool voiceOn,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
    child: Row(
      // Buttons stay on the last line as long text wraps and the box grows.
      crossAxisAlignment: CrossAxisAlignment.end,
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
                  // Wrap long input instead of scrolling it sideways out of
                  // view; Enter still sends (action isn't `newline`).
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.text,
                  maxLength: 500,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                ),
        ),
        if (voice.available && voiceOn)
          ShadTooltip(
            builder: (_) => Text(voice.listening ? 'Stop listening' : 'Speak'),
            child: ShadIconButton.outline(
              width: 38,
              height: 38,
              decoration: ShadDecoration(
                border: ShadBorder.all(
                  radius: BorderRadius.circular(999),
                  color: voice.listening ? coral : cs.border,
                ),
              ),
              icon: Icon(
                voice.listening ? LucideIcons.micOff : LucideIcons.mic,
                size: 17,
              ),
              onPressed: _toggleMic,
              foregroundColor: voice.listening ? coral : null,
            ),
          ),
        const SizedBox(width: 6),
        ShadTooltip(
          builder: (_) => const Text('Send  Enter'),
          child: ShadIconButton(
            width: 38,
            height: 38,
            decoration: ShadDecoration(
              border: ShadBorder.all(radius: BorderRadius.circular(999)),
            ),
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
        ),
      ],
    ),
  );
}
