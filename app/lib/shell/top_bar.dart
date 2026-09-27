import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../api/api.dart';
import '../auth/auth.dart';
import '../chat/chat_controller.dart';
import '../chat/models.dart';
import '../settings/preferences.dart';
import '../theme.dart';
import '../widgets/tappable.dart';
import 'history.dart';
import 'recommended_rail.dart';
import 'shortcuts.dart';

/// Desktop/tablet top bar (OTTAI-11): global search, the Recommended sheet
/// (tablets, where there's no rail), Theater Mode toggle, avatar.
class TopBar extends ConsumerWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final playing = ref.watch(chatProvider.select((s) => s.playerOpen));
    final mode = ref.watch(playerModeProvider);
    final user = ref.watch(authProvider.select((a) => a.user));
    final railSheet =
        MediaQuery.sizeOf(context).width < railBreakpoint &&
        ref.watch(chatProvider.select((s) => s.hasVideos));
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.border)),
      ),
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: const GlobalSearch(),
                  ),
                ),
              ),
              if (railSheet) ...[
                const SizedBox(width: 12),
                const RecommendedButton(),
              ],
              const SizedBox(width: 12),
              ShadTooltip(
                builder: (_) => Text(
                  playing
                      ? (mode == PlayerMode.theater
                            ? 'Back to mini player  I'
                            : 'Large player  T')
                      : 'Videos open in the ${mode == PlayerMode.mini ? 'mini player' : 'theater'}',
                ),
                child: ShadButton.outline(
                  size: ShadButtonSize.sm,
                  leading: Icon(
                    mode == PlayerMode.theater
                        ? LucideIcons.pictureInPicture2
                        : LucideIcons.monitorPlay,
                    size: 15,
                  ),
                  onPressed: ref.read(playerModeProvider.notifier).toggle,
                  child: Text(
                    mode == PlayerMode.theater ? 'Mini player' : 'Theater mode',
                  ),
                ),
              ),
              if (user != null) ...[
                const SizedBox(width: 12),
                ShadAvatar(
                  null,
                  size: const Size.square(34),
                  backgroundColor: coralSoftOn(context),
                  placeholder: Text(
                    user.isDemo
                        ? 'D'
                        : user.email.substring(0, 1).toUpperCase(),
                    style: theme.textTheme.small.copyWith(
                      color: coralOn(context),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Search box with a results dropdown: matching chats (local) and catalog videos
/// (`/videos/search`, debounced).
class GlobalSearch extends ConsumerStatefulWidget {
  const GlobalSearch({super.key});

  @override
  ConsumerState<GlobalSearch> createState() => _GlobalSearchState();
}

class _GlobalSearchState extends ConsumerState<GlobalSearch> {
  final _popover = ShadPopoverController();
  final _text = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<Video> _videos = const [];
  bool _loading = false;

  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _focus = ref.read(searchFocusProvider)..addListener(_onFocus);
  }

  void _onFocus() {
    if (_focus.hasFocus && _query.isNotEmpty) _popover.show();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _debounce?.cancel();
    _popover.dispose();
    _text.dispose();
    super.dispose();
  }

  void _changed(String v) {
    setState(() => _query = v.trim());
    _debounce?.cancel();
    if (_query.isEmpty) {
      _popover.hide();
      return;
    }
    _popover.show();
    _debounce = Timer(const Duration(milliseconds: 300), _searchVideos);
  }

  Future<void> _searchVideos() async {
    final q = _query;
    setState(() => _loading = true);
    try {
      final data = await ref.read(apiProvider).get('/videos/search', {'q': q});
      if (!mounted || q != _query) return;
      setState(() {
        _videos = [
          for (final v in data as List)
            Video.fromJson(v as Map<String, dynamic>),
        ];
        _loading = false;
      });
    } on ApiException {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _close() {
    _popover.hide();
    _text.clear();
    setState(() {
      _query = '';
      _videos = const [];
    });
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final cs = theme.colorScheme;
    final chats = ref.watch(historyProvider).value ?? const <Conversation>[];
    final q = _query.toLowerCase();
    final chatHits = q.isEmpty
        ? const <Conversation>[]
        : chats
              .where((c) => c.title.toLowerCase().contains(q))
              .take(4)
              .toList();
    final chat = ref.read(chatProvider.notifier);

    Widget section(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Text(label, style: mono(context, size: 11)),
    );

    final screenWidth = MediaQuery.sizeOf(context).width;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final popoverWidth = (screenWidth - 32).clamp(280.0, 440.0);
    final popoverMaxHeight = (screenHeight - 80).clamp(200.0, 420.0);

    return ShadPopover(
      controller: _popover,
      padding: const EdgeInsets.all(6),
      anchor: const ShadAnchor(
        childAlignment: Alignment.topLeft,
        overlayAlignment: Alignment.bottomLeft,
        offset: Offset(0, 6),
      ),
      popover: (context) => SizedBox(
        width: popoverWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: popoverMaxHeight),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
              if (chatHits.isNotEmpty) section('CHATS'),
              for (final c in chatHits)
                Tappable(
                  radius: 8,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  onTap: () {
                    _close();
                    chat.open(c);
                  },
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.messageSquare,
                        size: 14,
                        color: cs.mutedForeground,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.small,
                        ),
                      ),
                    ],
                  ),
                ),
              section(_loading ? 'VIDEOS · searching…' : 'VIDEOS'),
              if (!_loading && _videos.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
                  child: Text(
                    'No videos match yet.',
                    style: theme.textTheme.muted,
                  ),
                ),
              for (final v in _videos)
                Tappable(
                  radius: 8,
                  padding: const EdgeInsets.all(6),
                  onTap: () {
                    _close();
                    chat.play(v);
                  },
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(
                          v.thumbnail,
                          width: 80,
                          height: 45,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              const SizedBox(width: 80, height: 45),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              v.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.small.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              v.channel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.muted.copyWith(
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
      child: ShadInput(
        controller: _text,
        focusNode: _focus,
        placeholder: const Text('Search chats and videos…'),
        leading: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Icon(LucideIcons.search, size: 15, color: cs.mutedForeground),
        ),
        trailing: ShadBadge.outline(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
          child: Text(shortcutLabel('K'), style: mono(context, size: 11)),
        ),
        onChanged: _changed,
        onSubmitted: (_) {
          if (_videos.isNotEmpty) {
            final v = _videos.first;
            _close();
            chat.play(v);
          }
        },
      ),
    );
  }
}

/// Topic • session title, plus "Sync active" while a video plays (OTTAI-11).
class SessionBreadcrumb extends ConsumerWidget {
  const SessionBreadcrumb({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ShadTheme.of(context);
    final s = ref.watch(chatProvider);
    if (s.messages.isEmpty) return const SizedBox.shrink();
    final chats = ref.watch(historyProvider).value ?? const <Conversation>[];
    final title =
        chats.where((c) => c.id == s.conversationId).firstOrNull?.title ??
        s.messages.first.text;
    final i = s.activeReplyIndex;
    final topic =
        s.nowPlaying?.topic ??
        (i == null ? null : s.messages[i].videos.firstOrNull?.topic);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: contentMaxWidth),
          child: Row(
            children: [
              Expanded(
                child: ShadBreadcrumb(
                  children: [
                    if (topic != null && topic.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.graduationCap,
                            size: 14,
                            color: coralOn(context),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _cap(topic),
                            style: theme.textTheme.muted.copyWith(fontSize: 13),
                          ),
                        ],
                      ),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.small.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (s.playerOpen) ...[
                const SizedBox(width: 12),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    color: success,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox.square(dimension: 7),
                ),
                const SizedBox(width: 6),
                Text('Sync active', style: mono(context, size: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _cap(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
