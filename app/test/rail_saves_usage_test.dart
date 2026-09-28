// Recommended rail, per-chat saves, model and token usage (Epic OTTAI-21).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ott_ai/api/api.dart';
import 'package:ott_ai/auth/auth.dart';
import 'package:ott_ai/chat/chat_controller.dart';
import 'package:ott_ai/chat/models.dart';
import 'package:ott_ai/chat/reply.dart';
import 'package:ott_ai/chat/status_line.dart';
import 'package:ott_ai/library/saved.dart';
import 'package:ott_ai/shell/top_bar.dart';
import 'package:ott_ai/theme.dart';
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

String _id(String c) => c * 11;

/// A reply with [main] first, [others] after it, and a stored rail.
Map<String, dynamic> _reply(
  String main, {
  List<String> others = const [],
  List<String>? rail,
  String? model = 'llama3.2:3b',
  int prompt = 120,
  int output = 30,
  String cid = 'c1',
}) => {
  'conversation_id': cid,
  'reply': 'Here you go.',
  'videos': [
    for (final v in [main, ...others]) _v(_id(v)),
  ],
  'recommendations': [for (final v in rail ?? others) _v(_id(v))],
  'action': null,
  'source': 'catalog',
  'model': model,
  'prompt_tokens': prompt,
  'output_tokens': output,
  'usage': {
    'context_tokens': 700,
    'context_limit': 4096,
    'history_window': 6,
    'trimmed': false,
  },
};

void main() {
  late ProviderContainer c;
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    c.read(playerHandleProvider).attach(RecordingTransport());
  });
  tearDown(() => c.dispose());

  ChatController chat() => c.read(chatProvider.notifier);
  ChatState state() => c.read(chatProvider);
  List<String> ids(List<Video> vs) => [for (final v in vs) v.youtubeId];

  Future<void> ask(Map<String, dynamic> reply) async {
    api.onChat = (_) => reply;
    await chat().send('question');
  }

  group('mergeRecommendations', () {
    test('drops duplicates and the main video, best match first', () {
      Video v(String id, [int? m]) => Video.fromJson(_v(_id(id), match: m));
      final out = mergeRecommendations(
        [v('a'), v('b', 40), v('c')],
        [v('a', 99), v('b', 90), v('d', 70), v('e')],
      );
      // The reply's own copy of b (40%) wins over the related one (90%).
      expect(ids(out), [_id('d'), _id('b'), _id('c'), _id('e')]);
    });
  });

  group('rail per reply (OTTAI-22..24)', () {
    test('shows the latest reply and nothing autoplays', () async {
      await ask(_reply('a', others: ['b'], rail: ['b', 'r']));
      expect(state().nowPlaying, isNull);
      expect(ids(state().rail), [_id('b'), _id('r')]);
      await ask(_reply('c', rail: ['d']));
      expect(ids(state().rail), [_id('d')]);
    });

    test(
      'an earlier reply swaps the rail; back to latest restores it',
      () async {
        await ask(_reply('a', rail: ['b', 'r']));
        await ask(_reply('c', rail: ['d', 'e']));
        expect(state().railShowsEarlier, isFalse);

        chat().showRecommendationsFor(1); // the first reply
        expect(state().railShowsEarlier, isTrue);
        expect(ids(state().rail), [_id('b'), _id('r')]);

        // "next" follows whichever list the rail is showing.
        chat().play(Video.fromJson(_v(_id('c'))));
        chat().next();
        expect(state().nowPlaying?.youtubeId, _id('b'));

        chat().backToLatest();
        expect(ids(state().rail), [_id('d'), _id('e')]);
        chat().next();
        expect(state().nowPlaying?.youtubeId, _id('d'));
      },
    );

    test('the latest reply wins even while an earlier video plays, and a new '
        'reply moves the rail on', () async {
      await ask(_reply('a', rail: ['b']));
      await ask(_reply('c', rail: ['d']));
      chat().play(Video.fromJson(_v(_id('a'))));
      expect(ids(state().rail), [_id('d')]);
      chat().showRecommendationsFor(1);
      await ask(_reply('e', rail: ['f']));
      expect(state().railShowsEarlier, isFalse);
      expect(ids(state().rail), [_id('f')]);
    });

    test('stopping a video keeps the recommendations', () async {
      await ask(_reply('a', rail: ['b']));
      chat().play(Video.fromJson(_v(_id('a'))));
      chat().stopFromUi();
      expect(state().playerOpen, isFalse);
      expect(ids(state().rail), [_id('b')]);
    });

    test('next skips videos already played in this chat', () async {
      await ask(_reply('a', rail: ['b', 'd']));
      chat().play(Video.fromJson(_v(_id('b'))));
      chat().play(Video.fromJson(_v(_id('a'))));
      expect(ids(state().upNext), [_id('d')]);
    });

    test('a reopened chat shows stored recommendations straight away; older '
        'replies look theirs up once per video', () async {
      api.conversationMessages['c9'] = [
        {'role': 'user', 'content': 'old question'},
        {
          'role': 'assistant',
          'content': 'old reply',
          'videos': [_v(_id('a')), _v(_id('b'), match: 50)],
          'recommendations': null,
        },
        {'role': 'user', 'content': 'new question'},
        {
          'role': 'assistant',
          'content': 'new reply',
          'videos': [_v(_id('c'))],
          'recommendations': [_v(_id('d'), match: 80)],
          'source': 'catalog',
          'model': 'qwen3.5:4b',
          'prompt_tokens': 200,
          'output_tokens': 50,
        },
      ];
      await chat().open(
        Conversation(id: 'c9', title: 'x', updatedAt: DateTime(2026)),
      );
      expect(ids(state().rail), [_id('d')]);
      expect(api.gets.where((g) => g.endsWith('/recommendations')), isEmpty);

      chat().showRecommendationsFor(1);
      expect(state().loadingFor(1), isTrue);
      await Future<void>.delayed(Duration.zero);
      // other result (50%) first, then the looked-up related video (no match)
      expect(ids(state().rail), [_id('b'), 'rrrrrrrrrrr']);
      chat().backToLatest();
      chat().showRecommendationsFor(1);
      await Future<void>.delayed(Duration.zero);
      expect(api.gets.where((g) => g.endsWith('/recommendations')).length, 1);
    });
  });

  group('saves per chat (OTTAI-25/26)', () {
    setUp(() => c.read(authProvider.notifier).startDemo());

    Future<void> openChat(String id) async {
      api.conversationMessages[id] = [
        {'role': 'user', 'content': 'q'},
      ];
      await chat().open(
        Conversation(id: id, title: id, updatedAt: DateTime(2026)),
      );
      await Future<void>.delayed(Duration.zero);
      c.read(savedProvider); // start listening, as the sidebar does
      await Future<void>.delayed(Duration.zero);
    }

    test('toggle saves and removes; failures roll back', () async {
      await openChat('cA');
      final v = Video.fromJson(_v(_id('a')));
      final saved = c.read(savedProvider.notifier);
      await saved.toggle(v);
      expect(saved.isSaved(v.youtubeId), isTrue);
      expect(api.saved['cA'], [v.youtubeId]);
      await saved.toggle(v);
      expect(saved.isSaved(v.youtubeId), isFalse);

      api.failWrites = true;
      await expectLater(saved.save(v), throwsA(isA<ApiException>()));
      expect(saved.isSaved(v.youtubeId), isFalse);
    });

    test('saving in chat A does not mark the video saved in chat B; '
        'switching chats switches the list', () async {
      final v = Video.fromJson(_v(_id('a')));
      await openChat('cA');
      await c.read(savedProvider.notifier).save(v);
      expect(ids(c.read(savedProvider)!), [v.youtubeId]);

      await openChat('cB');
      expect(c.read(savedProvider), isEmpty);
      expect(c.read(savedProvider.notifier).isSaved(v.youtubeId), isFalse);

      await openChat('cA');
      expect(ids(c.read(savedProvider)!), [v.youtubeId]);
    });

    test(
      'saving the same video twice in one chat does nothing extra',
      () async {
        await openChat('cA');
        final v = Video.fromJson(_v(_id('a')));
        await c.read(savedProvider.notifier).save(v);
        await c.read(savedProvider.notifier).save(v);
        expect(api.saveCalls, 1);
        expect(c.read(savedProvider)!.length, 1);
      },
    );

    test('a new chat starts with no saves and can’t save yet', () async {
      await openChat('cA');
      await c.read(savedProvider.notifier).save(Video.fromJson(_v(_id('a'))));
      chat().newChat();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(savedProvider), isEmpty);
      await c.read(savedProvider.notifier).save(Video.fromJson(_v(_id('b'))));
      expect(api.saveCalls, 1);
    });

    test('"save this" saves the playing video to the current chat', () async {
      await ask(_reply('a'));
      c.read(savedProvider);
      await Future<void>.delayed(Duration.zero);
      chat().play(Video.fromJson(_v(_id('b'))));
      chat().apply(const PlayerAction(ActionType.save));
      await Future<void>.delayed(Duration.zero);
      expect(api.saved['c1'], [_id('b')]);
      expect(c.read(savedProvider.notifier).isSaved(_id('b')), isTrue);
    });
  });

  group('model and tokens (OTTAI-27)', () {
    test('compactTokens', () {
      expect(compactTokens(412), '412');
      expect(compactTokens(1234), '1.2k');
      expect(compactTokens(4096), '4.1k');
      expect(compactTokens(4000), '4k');
      expect(compactTokens(131072), '131k');
      expect(compactContext(4096), '4k');
      expect(compactContext(131072), '128k');
      expect(compactContext(3000), '3k');
    });

    test('replies carry model and tokens; the chat totals them', () async {
      await chat().loadModels();
      await ask(_reply('a', prompt: 120, output: 30));
      await ask(_reply('b', prompt: 200, output: 40));
      final s = state();
      expect(s.messages.last.model, 'llama3.2:3b');
      expect(s.messages.last.tokens, 240);
      expect(s.tokensUsed, 390);
      expect((s.contextTokens, s.contextLimit), (700, 4096));
    });

    test(
      'fallback replies say no LLM and add no tokens; commands are marked',
      () async {
        await ask(_reply('a', model: null, prompt: 0, output: 0));
        expect(state().messages.last.model, isNull);
        expect(state().tokensUsed, 0);
        api.onChat = (_) => {
          'conversation_id': 'c1',
          'reply': 'Nothing is playing right now.',
          'source': 'command',
        };
        await chat().send('pause');
        expect(state().messages.last.command, isTrue);
      },
    );

    test(
      'switching the model changes the next request and the meter',
      () async {
        await chat().loadModels();
        expect(state().model, 'llama3.2:3b');
        await ask(_reply('a'));
        chat().setModel('qwen3.5:4b');
        await Future<void>.delayed(Duration.zero);
        expect(state().contextLimit, 8192);
        expect(api.gets, contains('/conversations/c1/usage?qwen3.5:4b'));
        await ask(_reply('b', model: 'qwen3.5:4b'));
        expect(api.sent.last['model'], 'qwen3.5:4b');
        expect(state().messages.last.model, 'qwen3.5:4b');
      },
    );

    test('a reopened chat answers with the model it last used', () async {
      await chat().loadModels();
      api.conversationMessages['c7'] = [
        {'role': 'user', 'content': 'q'},
        {'role': 'assistant', 'content': 'r', 'model': 'qwen3.5:4b'},
        {'role': 'assistant', 'content': 'Paused.', 'source': 'command'},
      ];
      await chat().open(
        Conversation(id: 'c7', title: 'x', updatedAt: DateTime(2026)),
      );
      expect(state().model, 'qwen3.5:4b');
      chat().newChat();
      expect(state().model, 'llama3.2:3b');
    });
  });

  group('widgets', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await c.read(authProvider.notifier).startDemo();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: ShadApp(
            theme: lightTheme(),
            home: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('reply header shows model and tokens, or no LLM', (
      tester,
    ) async {
      await ask(_reply('a', prompt: 300, output: 112));
      await ask(_reply('b', model: null, prompt: 0, output: 0));
      final s = state();
      await pump(
        tester,
        Column(
          children: [
            AssistantReply(message: s.messages[1], index: 1),
            AssistantReply(message: s.messages[3], index: 3),
          ],
        ),
      );
      expect(find.text('llama3.2:3b · 412 tok'), findsOneWidget);
      expect(find.text('no LLM'), findsOneWidget);
    });

    testWidgets('status line: model, context meter, tokens used', (
      tester,
    ) async {
      await chat().loadModels();
      api.onChat = (_) => {
        ..._reply('a', prompt: 3000, output: 400),
        'usage': {
          'context_tokens': 3500,
          'context_limit': 4096,
          'history_window': 6,
          'trimmed': true,
        },
      };
      await chat().send('q');
      await pump(tester, const ChatStatusLine());
      expect(find.text('llama3.2:3b'), findsOneWidget);
      expect(find.text('ctx 3.5k / 4k'), findsOneWidget);
      expect(find.text('3.4k tokens'), findsOneWidget);
      expect(find.text('older messages trimmed'), findsOneWidget);
      // above 75%: amber
      final meter = tester.widget<ShadProgress>(find.byType(ShadProgress));
      expect(meter.color, warning);
    });

    testWidgets('video source picker is in the header, not the composer', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester, const TopBar());
      expect(find.byType(SourcePicker), findsOneWidget);
      expect(find.text('YouTube'), findsOneWidget);
      await pump(tester, const ChatStatusLine());
      expect(find.byType(SourcePicker), findsNothing);
    });
  });
}
