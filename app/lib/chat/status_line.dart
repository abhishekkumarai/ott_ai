import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../theme.dart';
import '../widgets/tappable.dart';
import 'chat_controller.dart';
import 'models.dart';

/// Inside the composer, below the input (OTTAI-27): the model answering in this chat (click to
/// switch), how full the next request's context is, and the tokens used so far.
class ChatStatusLine extends ConsumerWidget {
  const ChatStatusLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final aiOn = ref.watch(chatProvider.select((s) => s.models.isNotEmpty));
    final trimmed = ref.watch(
      chatProvider.select((s) => s.usage?.trimmed ?? false),
    );
    return Wrap(
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 14,
      runSpacing: 2,
      children: [
        if (aiOn) const _ModelPicker() else _mono(context, 'no LLM · keywords'),
        if (aiOn) const _ContextMeter(),
        const _TokensUsed(),
        if (trimmed) _mono(context, 'older messages trimmed', color: warning),
      ],
    );
  }
}

Widget _mono(BuildContext context, String text, {Color? color}) =>
    Text(text, style: mono(context, size: 11, color: color));

/// Amber above 75%, coral above 90%.
Color meterColor(BuildContext context, double share) => share > .9
    ? coral
    : share > .75
    ? warning
    : ShadTheme.of(context).colorScheme.mutedForeground;

class _ModelPicker extends ConsumerStatefulWidget {
  const _ModelPicker();

  @override
  ConsumerState<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends ConsumerState<_ModelPicker> {
  final _popover = ShadPopoverController();

  @override
  void dispose() {
    _popover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final models = ref.watch(chatProvider.select((s) => s.models));
    final model = ref.watch(chatProvider.select((s) => s.model));
    return ShadPopover(
      controller: _popover,
      padding: const EdgeInsets.all(6),
      anchor: const ShadAnchor(
        childAlignment: Alignment.bottomCenter,
        overlayAlignment: Alignment.topCenter,
        offset: Offset(0, -6),
      ),
      popover: (context) => SizedBox(
        width: 240,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: _mono(context, 'MODEL FOR THIS CHAT'),
            ),
            for (final m in models)
              Tappable(
                radius: 8,
                selected: m.name == model,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                semanticLabel: 'Use ${m.name}',
                onTap: () {
                  _popover.hide();
                  if (m.name != model) {
                    ref.read(chatProvider.notifier).setModel(m.name);
                  }
                },
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      child: m.name == model
                          ? Icon(LucideIcons.check, size: 14, color: coral)
                          : null,
                    ),
                    Expanded(
                      child: Text(
                        m.name,
                        style: mono(context, size: 12, color: cs.foreground),
                      ),
                    ),
                    if (m.context > 0)
                      _mono(context, '${compactContext(m.context)} ctx'),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Text(
                'New chats start with the model set in Settings.',
                style: theme.textTheme.muted.copyWith(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      child: ShadTooltip(
        builder: (_) => const Text('Switch the model for this chat'),
        child: ShadButton.ghost(
          size: ShadButtonSize.sm,
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          gap: 4,
          onPressed: _popover.toggle,
          leading: Icon(LucideIcons.cpu, size: 12, color: cs.mutedForeground),
          trailing: Icon(
            LucideIcons.chevronDown,
            size: 12,
            color: cs.mutedForeground,
          ),
          child: _mono(context, model ?? '—'),
        ),
      ),
    );
  }
}

class _ContextMeter extends ConsumerWidget {
  const _ContextMeter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final used = ref.watch(chatProvider.select((s) => s.contextTokens));
    final limit = ref.watch(chatProvider.select((s) => s.contextLimit));
    final window = ref.watch(
      chatProvider.select((s) => s.usage?.historyWindow ?? 6),
    );
    final trimmed = ref.watch(
      chatProvider.select((s) => s.usage?.trimmed ?? false),
    );
    final share = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;
    final color = meterColor(context, share);
    return ShadTooltip(
      builder: (_) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Text(
          'The next request starts at about $used of '
          '${limit > 0 ? '$limit' : '?'} context tokens. Only the last $window '
          'messages are sent to the model'
          '${trimmed ? '; older ones were trimmed to fit' : ''}.',
        ),
      ),
      child: Semantics(
        label: 'Context ${(share * 100).round()} percent full',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _mono(
              context,
              limit > 0
                  ? 'ctx ${compactTokens(used)} / ${compactContext(limit)}'
                  : 'ctx ${compactTokens(used)}',
              color: share > .75 ? color : null,
            ),
            if (limit > 0) ...[
              const SizedBox(width: 6),
              SizedBox(
                width: 40,
                child: ShadProgress(
                  value: share,
                  minHeight: 4,
                  color: color,
                  backgroundColor: ShadTheme.of(context).colorScheme.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TokensUsed extends ConsumerWidget {
  const _TokensUsed();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(chatProvider.select((s) => s.messages));
    final replies = [
      for (final (i, m) in messages.indexed)
        if (m.role == Role.assistant && m.tokens > 0) (i, m),
    ];
    final prompt = replies.fold(0, (n, r) => n + r.$2.promptTokens);
    final output = replies.fold(0, (n, r) => n + r.$2.outputTokens);
    final shown = replies.length > 8
        ? replies.sublist(replies.length - 8)
        : replies;
    return ShadTooltip(
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (replies.isEmpty) const Text('No model replies in this chat yet.'),
          if (replies.length > shown.length)
            Text('… ${replies.length - shown.length} earlier replies'),
          for (final (i, m) in shown)
            Text(
              'Reply ${i + 1} · ${m.model ?? 'no LLM'} · '
              '${m.promptTokens} in + ${m.outputTokens} out',
            ),
          if (replies.isNotEmpty)
            Text(
              'Total: $prompt prompt + $output output',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
        ],
      ),
      child: _mono(context, '${compactTokens(prompt + output)} tokens'),
    );
  }
}

class MediaSourceOption {
  const MediaSourceOption({
    required this.id,
    required this.label,
    required this.shortLabel,
    required this.subtitle,
    required this.icon,
    this.isVerified = true,
  });

  final String id;
  final String label;
  final String shortLabel;
  final String subtitle;
  final IconData icon;
  final bool isVerified;
}

const mediaSourceOptions = [
  MediaSourceOption(
    id: 'youtube',
    label: 'YouTube',
    shortLabel: 'YouTube',
    subtitle: 'Curated learning videos & topics',
    icon: LucideIcons.video,
  ),
  MediaSourceOption(
    id: 'vidy',
    label: 'Vidy (All Media)',
    shortLabel: 'Vidy · All',
    subtitle: 'Stream free movies, shows & anime',
    icon: LucideIcons.film,
  ),
  MediaSourceOption(
    id: 'vidy_movie',
    label: 'Vidy · Movies',
    shortLabel: 'Vidy · Movies',
    subtitle: 'Feature films via TMDB',
    icon: LucideIcons.clapperboard,
  ),
  MediaSourceOption(
    id: 'vidy_tv',
    label: 'Vidy · TV Series',
    shortLabel: 'Vidy · TV',
    subtitle: 'Television seasons & episodes',
    icon: LucideIcons.tv,
  ),
  MediaSourceOption(
    id: 'vidy_anime',
    label: 'Vidy · Anime',
    shortLabel: 'Vidy · Anime',
    subtitle: 'Anime library via AniList',
    icon: LucideIcons.sparkles,
  ),
];

/// The video streaming source for new searches (YouTube, Vidy, …). Lives in
/// the page header, so its menu opens downward.
class SourcePicker extends ConsumerStatefulWidget {
  const SourcePicker({super.key});

  @override
  ConsumerState<SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends ConsumerState<SourcePicker> {
  final _popover = ShadPopoverController();

  @override
  void dispose() {
    _popover.dispose();
    super.dispose();
  }

  List<MediaSourceOption> _buildOptions(List<StreamProviderInfo> verified) {
    if (verified.isEmpty) return mediaSourceOptions;

    final options = <MediaSourceOption>[];
    for (final p in verified) {
      if (p.id == 'youtube') {
        options.add(
          const MediaSourceOption(
            id: 'youtube',
            label: 'YouTube',
            shortLabel: 'YouTube',
            subtitle: 'Curated learning videos & topics',
            icon: LucideIcons.video,
            isVerified: true,
          ),
        );
      } else if (p.id == 'vidy') {
        options.add(
          const MediaSourceOption(
            id: 'vidy',
            label: 'Vidy (All Media)',
            shortLabel: 'Vidy · All',
            subtitle: 'Stream free movies, shows & anime',
            icon: LucideIcons.film,
            isVerified: true,
          ),
        );
        options.add(
          const MediaSourceOption(
            id: 'vidy_movie',
            label: 'Vidy · Movies',
            shortLabel: 'Vidy · Movies',
            subtitle: 'Feature films via TMDB',
            icon: LucideIcons.clapperboard,
            isVerified: true,
          ),
        );
        options.add(
          const MediaSourceOption(
            id: 'vidy_tv',
            label: 'Vidy · TV Series',
            shortLabel: 'Vidy · TV',
            subtitle: 'Television seasons & episodes',
            icon: LucideIcons.tv,
            isVerified: true,
          ),
        );
        options.add(
          const MediaSourceOption(
            id: 'vidy_anime',
            label: 'Vidy · Anime',
            shortLabel: 'Vidy · Anime',
            subtitle: 'Anime library via AniList',
            icon: LucideIcons.sparkles,
            isVerified: true,
          ),
        );
      } else {
        final IconData icon;
        final String sub;
        if (p.category == 'anime') {
          icon = LucideIcons.sparkles;
          sub = 'Anime library via AniList';
        } else if (p.category == 'free_vod') {
          icon = LucideIcons.monitorPlay;
          sub = 'Free on-demand movies';
        } else {
          icon = LucideIcons.film;
          sub = 'Multi-stream movies & TV';
        }
        options.add(
          MediaSourceOption(
            id: p.id,
            label: p.name,
            shortLabel: p.name.split(' ').first,
            subtitle: sub,
            icon: icon,
            isVerified: true,
          ),
        );
      }
    }
    return options;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final active = ref.watch(chatProvider.select((s) => s.activeSource));
    final verifiedAsync = ref.watch(verifiedProvidersProvider);
    final verifiedList = verifiedAsync.value ?? const [];
    final options = _buildOptions(verifiedList);

    final current = options.firstWhere(
      (o) => o.id == active,
      orElse: () => options.first,
    );
    final isCustom = active != 'youtube';

    return ShadPopover(
      controller: _popover,
      padding: const EdgeInsets.all(6),
      anchor: const ShadAnchor(
        childAlignment: Alignment.topRight,
        overlayAlignment: Alignment.bottomRight,
        offset: Offset(0, 6),
      ),
      popover: (context) => SizedBox(
        width: 260,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 380),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _mono(context, 'STREAMING SOURCE'),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Color(0xFF10B981),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          _mono(
                            context,
                            'verified',
                            color: const Color(0xFF10B981),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                for (final opt in options)
                  Tappable(
                    radius: 8,
                    selected: opt.id == active,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    semanticLabel: 'Select ${opt.label}',
                    onTap: () {
                      _popover.hide();
                      if (opt.id != active) {
                        ref.read(chatProvider.notifier).setSource(opt.id);
                      }
                    },
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          child: opt.id == active
                              ? Icon(LucideIcons.check, size: 14, color: coral)
                              : null,
                        ),
                        Icon(
                          opt.icon,
                          size: 14,
                          color: opt.id == active ? coral : cs.mutedForeground,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      opt.label,
                                      style: mono(
                                        context,
                                        size: 12,
                                        color: cs.foreground,
                                      ),
                                    ),
                                  ),
                                  if (opt.isVerified)
                                    Container(
                                      width: 6,
                                      height: 6,
                                      margin: const EdgeInsets.only(left: 4),
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF10B981),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                ],
                              ),
                              Text(
                                opt.subtitle,
                                style: theme.textTheme.muted.copyWith(
                                  fontSize: 10,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                  child: Text(
                    'Sources are automatically audited for live stream health.',
                    style: theme.textTheme.muted.copyWith(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      child: ShadTooltip(
        builder: (_) => const Text('Switch video streaming source'),
        child: ShadButton.ghost(
          size: ShadButtonSize.sm,
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          gap: 4,
          onPressed: _popover.toggle,
          leading: Icon(
            current.icon,
            size: 12,
            color: isCustom ? coral : cs.mutedForeground,
          ),
          trailing: Icon(
            LucideIcons.chevronDown,
            size: 12,
            color: cs.mutedForeground,
          ),
          child: _mono(
            context,
            current.shortLabel,
            color: isCustom ? coral : null,
          ),
        ),
      ),
    );
  }
}
