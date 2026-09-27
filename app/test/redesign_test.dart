// Unit tests for the chat-first redesign (OTTAI-3..14): models, player commands,
// "next" order, looping, preferences applied on play, autoplay.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ott_ai/api/api.dart';
import 'package:ott_ai/auth/auth.dart';
import 'package:ott_ai/chat/chat_controller.dart';
import 'package:ott_ai/chat/models.dart';
import 'package:ott_ai/chat/reply.dart';
import 'package:ott_ai/chat/widgets.dart';
import 'package:ott_ai/widgets/tappable.dart';
import 'package:ott_ai/player/transcript.dart';
import 'package:ott_ai/player/player_handle.dart';
import 'package:ott_ai/settings/preferences.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'widget_test.dart' show FakeApi, RecordingTransport;

Map<String, dynamic> _v(String id, {int? match}) => {
  'youtube_id': id,
  'title': 'Video $id',
  'channel': 'Chan',
  'duration_s': 600,
  'topic': 'astronomy',
  'match': ?match,
};

void main() {
  group('models', () {
    test('Video.match accepts 1–99 only', () {
      expect(Video.fromJson(_v('aaaaaaaaaaa', match: 87)).match, 87);
      expect(Video.fromJson(_v('aaaaaaaaaaa', match: 0)).match, isNull);
      expect(Video.fromJson(_v('aaaaaaaaaaa', match: 400)).match, isNull);
      expect(Video.fromJson(_v('aaaaaaaaaaa')).match, isNull);
    });

    test('chapterAt picks the chapter containing t', () {
      const ch = [Chapter(0, 'a'), Chapter(60, 'b'), Chapter(120, 'c')];
      expect(chapterAt(ch, 0), 0);
      expect(chapterAt(ch, 59.9), 0);
      expect(chapterAt(ch, 60), 1);
      expect(chapterAt(ch, 500), 2);
      expect(chapterAt(const [], 10), isNull);
    });

    test('PlayerAction parses loop ranges and new commands', () {
      final a = PlayerAction.fromJson({'type': 'loop', 'start': 60, 'end': 90});
      expect((a!.type, a.start, a.end), (ActionType.loop, 60.0, 90.0));
      expect(PlayerAction.fromJson({'type': 'mute'})!.type, ActionType.mute);
      expect(
        PlayerAction.fromJson({'type': 'unloop'})!.type,
        ActionType.unloop,
      );
    });

    test('PlayerEvent reads the full state snapshot', () {
      final e = PlayerEvent.fromMap({
        'type': 'time',
        't': 5,
        'd': 100,
        'volume': 40,
        'muted': false,
        'rate': 1.5,
        'quality': '1080p',
        'loopA': 10,
        'loopB': 20,
      });
      expect(
        (e.volume, e.rate, e.quality, e.loopA, e.loopB, e.hasLoop),
        (40.0, 1.5, '1080p', 10.0, 20.0, true),
      );
      expect(
        PlayerEvent.fromMap({'type': 'time', 'quality': 'x' * 40}).quality,
        isNull,
      );
    });
  });

  group('player commands', () {
    test('seekTo / volume / rate / loop go through the transport', () {
      final h = PlayerHandle();
      final t = RecordingTransport();
      h.attach(t);
      h.seekTo(42);
      h.setVolume(30);
      h.setRate(.75);
      h.loop(10, 5); // invalid range: ignored
      h.loop(10, 40);
      h.unloop();
      expect(t.calls, [
        'seekTo:42.0',
        'setVolume:30.0',
        'setRate:0.75',
        'loop:40.0',
        'unloop',
      ]);
    });
  });

  group('ChatController', () {
    late ProviderContainer c;
    late FakeApi api;
    late RecordingTransport transport;

    setUp(() {
      api = FakeApi();
      c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
      transport = RecordingTransport();
      c.read(playerHandleProvider).attach(transport);
    });
    tearDown(() => c.dispose());

    Future<void> ask(List<Map<String, dynamic>> videos) async {
      api.onChat = (_) => {
        'conversation_id': 'c1',
        'reply': 'Here are clear explainers on collapsing stars.',
        'videos': videos,
        // As the server stores it: other results, then related videos.
        'recommendations': [...videos.skip(1), _v('rrrrrrrrrrr')],
        'highlights': ['collapsing stars', 'not in the reply'],
        'action': null,
        'source': 'catalog',
      };
      final chat = c.read(chatProvider.notifier);
      await chat.send('black holes');
      // Replies don't autoplay; these tests start the top result like a user.
      final reply = c.read(chatProvider).messages.last;
      if (reply.videos.isNotEmpty) chat.play(reply.videos.first);
      await Future<void>.delayed(Duration.zero);
    }

    test('a reply with videos does not start playing by itself', () async {
      api.onChat = (_) => {
        'conversation_id': 'c1',
        'reply': 'Here you go.',
        'videos': [_v('aaaaaaaaaaa'), _v('bbbbbbbbbbb')],
        'action': null,
        'source': 'catalog',
      };
      await c.read(chatProvider.notifier).send('black holes');
      expect(c.read(chatProvider).nowPlaying, isNull);
      expect(transport.calls, isEmpty);
      expect(c.read(chatProvider).messages.last.videos.length, 2);
    });

    test(
      'reply keeps only real highlights and records latency + source',
      () async {
        await ask([_v('aaaaaaaaaaa'), _v('bbbbbbbbbbb')]);
        final m = c.read(chatProvider).messages.last;
        expect(m.highlights, ['collapsing stars']);
        expect(m.latencyMs, isNotNull);
        expect(m.source, VideoSource.catalog);
      },
    );

    test(
      'up next = other answers first, then related; played ones skipped',
      () async {
        await ask([_v('aaaaaaaaaaa'), _v('bbbbbbbbbbb'), _v('ccccccccccc')]);
        final s = c.read(chatProvider);
        expect(s.activeReplyIndex, 1);
        expect(
          [for (final v in s.upNext) v.youtubeId],
          ['bbbbbbbbbbb', 'ccccccccccc', 'rrrrrrrrrrr'],
        );
        c.read(chatProvider.notifier).next();
        expect(c.read(chatProvider).nowPlaying?.youtubeId, 'bbbbbbbbbbb');
        await Future<void>.delayed(Duration.zero);
        expect(c.read(chatProvider).upNext.first.youtubeId, 'ccccccccccc');
      },
    );

    test('loop 3:40–5:10 and "loop this part" (current chapter)', () async {
      api.chapters = [
        {'start_s': 0, 'title': 'Intro'},
        {'start_s': 60, 'title': 'Part one'},
        {'start_s': 180, 'title': 'Part two'},
      ];
      await ask([_v('aaaaaaaaaaa')]);
      final chat = c.read(chatProvider.notifier);
      chat.apply(const PlayerAction(ActionType.loop, 0, 220, 310));
      expect(transport.calls.last, 'loop:310.0');

      await c.read(chaptersProvider('aaaaaaaaaaa').future);
      c
          .read(playerHandleProvider)
          .emit(const PlayerEvent('time', t: 90, d: 600, playing: true));
      await Future<void>.delayed(Duration.zero); // broadcast events are async
      chat.apply(const PlayerAction(ActionType.loop));
      // chapter "Part one" runs 60 → 180
      expect(transport.calls.last, 'loop:180.0');
      chat.apply(const PlayerAction(ActionType.unloop));
      expect(transport.calls.last, 'unloop');
    });

    test(
      'the end of a looped section repeats instead of autoplaying next',
      () async {
        await c.read(preferencesProvider.notifier).update({
          'autoplay_next': true,
        });
        await ask([_v('aaaaaaaaaaa'), _v('bbbbbbbbbbb')]);
        final h = c.read(playerHandleProvider);
        h.emit(
          PlayerEvent.fromMap({
            'type': 'time',
            't': 590,
            'd': 600,
            'loopA': 500,
            'loopB': 600,
          }),
        );
        await Future<void>.delayed(Duration.zero);
        h.emit(const PlayerEvent('ended', t: 600, d: 600));
        await Future<void>.delayed(Duration.zero);
        expect(c.read(chatProvider).nowPlaying?.youtubeId, 'aaaaaaaaaaa');
      },
    );

    test('a reloaded player gets speed, mute and loop back', () async {
      await ask([_v('aaaaaaaaaaa')]);
      final h = c.read(playerHandleProvider);
      h.emit(
        PlayerEvent.fromMap({
          'type': 'time',
          't': 120,
          'd': 600,
          'playing': true,
          'rate': 1.5,
          'muted': true,
          'loopA': 100,
          'loopB': 160,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      transport.calls.clear();
      h.emit(const PlayerEvent('ready'));
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, [
        'load:aaaaaaaaaaa',
        'setRate:1.5',
        'mute',
        'loop:160.0',
      ]);
    });

    test('mute toggles from player state', () async {
      await ask([_v('aaaaaaaaaaa')]);
      final chat = c.read(chatProvider.notifier);
      chat.toggleMute();
      expect(transport.calls.last, 'mute');
      c
          .read(playerHandleProvider)
          .emit(const PlayerEvent('time', t: 1, d: 600, muted: true));
      await Future<void>.delayed(Duration.zero);
      chat.toggleMute();
      expect(transport.calls.last, 'unmute');
    });

    test(
      'saved speed and start-muted apply on play; autoplay on end',
      () async {
        api.prefs = {
          'playback_rate': 1.5,
          'start_muted': true,
          'autoplay_next': true,
        };
        c.read(authProvider.notifier); // no user: load preferences directly
        await c.read(preferencesProvider.notifier).update({
          'playback_rate': 1.5,
        });
        await ask([_v('aaaaaaaaaaa'), _v('bbbbbbbbbbb')]);
        expect(transport.calls, containsAll(['setRate:1.5', 'mute']));
        c
            .read(playerHandleProvider)
            .emit(const PlayerEvent('ended', t: 600, d: 600));
        await Future<void>.delayed(Duration.zero);
        expect(c.read(chatProvider).nowPlaying?.youtubeId, 'bbbbbbbbbbb');
      },
    );

    test('a recreated player view resumes the video where it was', () async {
      await ask([_v('aaaaaaaaaaa')]);
      final h = c.read(playerHandleProvider);
      h.emit(const PlayerEvent('ready'));
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls.where((x) => x.startsWith('load')).length, 1);
      h.emit(const PlayerEvent('time', t: 95, d: 600, playing: true));
      await Future<void>.delayed(Duration.zero);
      h.emit(const PlayerEvent('ready')); // e.g. back from Settings
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls.last, 'load:aaaaaaaaaaa');
      expect(transport.calls.where((x) => x.startsWith('load')).length, 2);
      // OTTAI-19: controls show "play" until the new player reports playback.
      expect(c.read(playbackProvider).playing, isFalse);
      expect(c.read(playbackProvider).t, 95);
    });

    test(
      'player mode starts from preferences, then remembers the choice',
      () async {
        expect(c.read(playerModeProvider), PlayerMode.mini);
        c.read(playerModeProvider.notifier).toggle();
        expect(c.read(playerModeProvider), PlayerMode.theater);
      },
    );

    test('collapse state is remembered per block', () {
      c.read(collapseProvider.notifier).set('c1:1:recommended', false);
      expect(c.read(collapseProvider)['c1:1:recommended'], isFalse);
    });
  });

  group('code review fixes', () {
    test('401 from /auth/* is a wrong credential, not an expired session', () {
      expect(ApiClient.sessionExpired('/auth/change-password', 401), isFalse);
      expect(ApiClient.sessionExpired('/auth/login', 401), isFalse);
      expect(ApiClient.sessionExpired('/chat', 401), isTrue);
      expect(ApiClient.sessionExpired('/chat', 403), isFalse);
    });

    testWidgets('highlights survive Unicode case folding and match any case', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ShadApp(
          home: HighlightedText('İstanbul: SOURDOUGH starter tips', [
            'sourdough starter',
          ]),
        ),
      );
      final rich = tester.widget<RichText>(find.byType(RichText).first);
      final spans = (rich.text as TextSpan).children!.first as TextSpan;
      final parts = [for (final c in spans.children!) (c as TextSpan).text];
      expect(parts.join(), 'İstanbul: SOURDOUGH starter tips');
      expect(parts, contains('SOURDOUGH starter'));
    });

    testWidgets(
      'hidden hover actions are not tappable; shown without a mouse',
      (tester) async {
        var taps = 0;
        await tester.pumpWidget(
          ShadApp(
            home: Center(
              child: HoverReveal(
                hovered: false,
                child: GestureDetector(
                  key: const ValueKey('action'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox(width: 40, height: 40),
                ),
              ),
            ),
          ),
        );
        // The test binding has no mouse connected, like a touch screen.
        expect(
          tester
              .widget<Opacity>(
                find.ancestor(
                  of: find.byKey(const ValueKey('action')),
                  matching: find.byType(Opacity),
                ),
              )
              .opacity,
          1,
        );
        await tester.tap(find.byKey(const ValueKey('action')));
        await tester.pumpAndSettle();
        expect(taps, 1);
      },
    );
  });

  group('transcripts and summaries (OTTAI-20)', () {
    late ProviderContainer c;
    late FakeApi api;

    setUp(() {
      api = FakeApi();
      c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
      c.read(playerHandleProvider).attach(RecordingTransport());
    });
    tearDown(() => c.dispose());

    test('transcript lines keep optional timestamps', () {
      final a = TranscriptLine.fromJson({'start_s': 75, 'text': 'Stars'});
      final b = TranscriptLine.fromJson({'start_s': null, 'text': 'plain'});
      expect((a.start, a.text), (75.0, 'Stars'));
      expect(b.start, isNull);
    });

    test('summarize adds the request and the answer', () async {
      Object? body;
      api.onPost = (path, b) {
        expect(path, '/videos/aaaaaaaaaaa/summary');
        body = b;
        return {'summary': 'Stars collapse when fuel runs out.'};
      };
      await c
          .read(chatProvider.notifier)
          .summarize(
            video: Video.fromJson(_v('aaaaaaaaaaa')),
            start: 60,
            end: 180,
            label: 'Stars',
          );
      final msgs = c.read(chatProvider).messages;
      expect(msgs.map((m) => m.text), [
        'Summarize “Stars”',
        'Stars collapse when fuel runs out.',
      ]);
      expect(body, containsPair('start_s', 60.0));
      expect(body, containsPair('end_s', 180.0));
      expect(c.read(chatProvider).sending, isFalse);
    });

    test(
      'a failed summary shows the error and leaves no dangling request',
      () async {
        api.onPost = (_, _) => throw ApiException('The AI model is offline');
        await c
            .read(chatProvider.notifier)
            .summarize(video: Video.fromJson(_v('aaaaaaaaaaa')), label: 'All');
        final s = c.read(chatProvider);
        expect(s.messages, isEmpty);
        expect(s.error, 'The AI model is offline');
        expect(s.sending, isFalse);
      },
    );
  });

  group('collapse persistence (OTTAI-18)', () {
    testWidgets('a built block picks up toggles restored later', (
      tester,
    ) async {
      final store = _SlowStore({'c1:1:moments': false});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWithValue(FakeApi()),
            collapseStoreProvider.overrideWithValue(store),
          ],
          child: const ShadApp(
            home: SingleChildScrollView(
              child: CollapsibleBlock(
                stateKey: 'c1:1:moments',
                defaultOpen: true,
                title: Text('Key moments'),
                child: Text('chapter rows'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('chapter rows'), findsOneWidget); // default: open
      store.release();
      await tester.pumpAndSettle();
      expect(find.text('chapter rows'), findsNothing); // restored: closed
    });

    test('restores saved toggles, skips unsaved chats, caps entries', () async {
      final store = _MemoryStore({'c1:1:moments': false});
      final c = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(FakeApi()),
          collapseStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      c.read(collapseProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(collapseProvider)['c1:1:moments'], isFalse);

      final n = c.read(collapseProvider.notifier);
      n.set('new:3:recommended', false);
      await Future<void>.delayed(Duration.zero);
      expect(store.saved.containsKey('new:3:recommended'), isFalse);
      expect(c.read(collapseProvider)['new:3:recommended'], isFalse);

      for (var i = 0; i < CollapseController.maxEntries + 10; i++) {
        n.set('c$i:1:moments', i.isEven);
      }
      await Future<void>.delayed(Duration.zero);
      expect(c.read(collapseProvider).length, CollapseController.maxEntries);
      expect(
        store.saved.containsKey(
          'c${CollapseController.maxEntries + 9}:1:moments',
        ),
        isTrue,
      );
      expect(
        store.saved.containsKey('c1:1:moments'),
        isFalse,
      ); // oldest dropped
    });
  });
}

class _MemoryStore implements CollapseStore {
  _MemoryStore(this.saved);
  Map<String, bool> saved;

  @override
  Future<Map<String, bool>> load() async => {...saved};

  @override
  Future<void> save(Map<String, bool> entries) async => saved = {...entries};
}

class _SlowStore implements CollapseStore {
  _SlowStore(this._data);
  final Map<String, bool> _data;
  final _gate = Completer<void>();
  void release() => _gate.complete();

  @override
  Future<Map<String, bool>> load() async {
    await _gate.future;
    return {..._data};
  }

  @override
  Future<void> save(Map<String, bool> entries) async {}
}
