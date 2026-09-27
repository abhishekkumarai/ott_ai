import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ott_ai/api/api.dart';
import 'package:ott_ai/auth/auth.dart';
import 'package:ott_ai/auth/login_screen.dart';
import 'package:ott_ai/chat/chat_controller.dart';
import 'package:ott_ai/chat/chat_screen.dart';
import 'package:ott_ai/chat/models.dart';
import 'package:ott_ai/main.dart';
import 'package:ott_ai/player/player_handle.dart';
import 'package:ott_ai/theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Fake backend: canned /chat replies, no network.
class FakeApi extends ApiClient {
  final sent = <Map<String, dynamic>>[];
  Map<String, dynamic> Function(Map<String, dynamic> body)? onChat;

  FakeApi({this.session});
  final Map<String, dynamic>? session;
  int demoCalls = 0;

  @override
  Future<Map<String, dynamic>?> refresh() async => session;

  @override
  Future<Map<String, dynamic>> demo() async {
    demoCalls++;
    return {
      'access_token': 't',
      'user': {
        'id': 'u1',
        'email': 'demo-x@demo.invalid',
        'is_admin': false,
        'is_demo': true,
      },
    };
  }

  final gets = <String>[];

  @override
  Future<dynamic> get(String path, [Map<String, dynamic>? query]) async {
    gets.add(query == null ? path : '$path?${query.values.join(',')}');
    if (path == '/models') return models;
    if (path == '/me/preferences') return prefs;
    if (path.endsWith('/recommendations')) {
      return [_video('rrrrrrrrrrr', 'Related')];
    }
    if (path.endsWith('/chapters')) return chapters;
    final saves = _saves.firstMatch(path);
    if (saves != null) {
      return [for (final id in saved[saves[1]] ?? const []) _video(id, id)];
    }
    if (path.endsWith('/usage')) return usage(query?['model'] as String?);
    if (path.endsWith('/messages')) {
      return conversationMessages[path.split('/')[2]] ?? const [];
    }
    return [];
  }

  Map<String, dynamic> models = {
    'models': [
      {'name': 'llama3.2:3b', 'context': 4096},
      {'name': 'qwen3.5:4b', 'context': 8192},
    ],
    'default': 'llama3.2:3b',
    'base_context': 180,
    'history_window': 6,
  };
  Map<String, dynamic> Function(String? model) usage = (model) => {
    'prompt_tokens': 0,
    'output_tokens': 0,
    'context_tokens': 900,
    'context_limit': 4096,
    'history_window': 6,
    'trimmed': false,
  };

  /// GET /conversations/{id}/messages, by conversation id.
  final conversationMessages = <String, List<Map<String, dynamic>>>{};

  Map<String, dynamic> prefs = {};

  /// Saved video ids per conversation, newest first.
  final saved = <String, List<String>>{};
  int saveCalls = 0;
  bool failWrites = false;
  static final _saves = RegExp(r'^/conversations/([^/]+)/saved(?:/([^/]+))?$');

  @override
  Future<dynamic> put(String path, [Object? body]) async {
    if (failWrites) throw ApiException('Server said no');
    final m = _saves.firstMatch(path);
    if (m != null && m[2] != null) {
      saveCalls++;
      final list = saved.putIfAbsent(m[1]!, () => []);
      if (!list.contains(m[2])) list.insert(0, m[2]!);
    }
    return null;
  }

  @override
  Future<dynamic> delete(String path, [Object? body]) async {
    if (failWrites) throw ApiException('Server said no');
    final m = _saves.firstMatch(path);
    if (m != null && m[2] != null) saved[m[1]]?.remove(m[2]);
    return null;
  }

  List<Map<String, dynamic>> chapters = [];

  @override
  Future<dynamic> patch(String path, [Object? body]) async {
    prefs = {...prefs, ...Map<String, dynamic>.from(body as Map)};
    return prefs;
  }

  @override
  Future<dynamic> post(String path, [Object? body]) async {
    if (path == '/chat') {
      final b = Map<String, dynamic>.from(body as Map);
      sent.add(b);
      return onChat!(b);
    }
    if (onPost != null) return onPost!(path, body);
    return null;
  }

  /// Other POSTs (e.g. summaries); may throw ApiException.
  Object? Function(String path, Object? body)? onPost;
}

Map<String, dynamic> _video(String id, String title) => {
  'youtube_id': id,
  'title': title,
  'channel': 'Chan',
  'duration_s': 600,
  'topic': 't',
  'thumbnail': 'ignored',
};

class RecordingTransport implements PlayerTransport {
  final calls = <String>[];
  @override
  void send(
    String cmd, {
    String? id,
    double? start,
    double? end,
    double? seconds,
    double? value,
  }) => calls.add([cmd, ?id, ?seconds, ?value, ?end].join(':'));
}

void main() {
  group('models', () {
    test('formatTime', () {
      expect(formatTime(0), '0:00');
      expect(formatTime(65), '1:05');
      expect(formatTime(3725), '1:02:05');
      expect(formatTime(double.nan), '0:00');
    });

    test('Video.fromJson rejects bad ids and builds its own thumbnail', () {
      expect(
        () => Video.fromJson(_video('bad"id', 'x')),
        throwsFormatException,
      );
      final v = Video.fromJson({
        ..._video('aaaaaaaaaaa', 'x'),
        'thumbnail': 'javascript:alert(1)',
      });
      expect(v.thumbnail, 'https://i.ytimg.com/vi/aaaaaaaaaaa/mqdefault.jpg');
    });

    test('Video.fromJson parses Vidy media and keeps sanitized thumbnail', () {
      final v = Video.fromJson({
        'youtube_id': 'vidy:movie:315162',
        'title': 'Puss in Boots',
        'channel': 'Universal Pictures',
        'duration_s': 6120,
        'topic': 'Animation',
        'provider': 'vidy',
        'media_type': 'movie',
        'thumbnail':
            'https://image.tmdb.org/t/p/w500/1NqwE62Xvum27eRPi4QVod7YWoG.jpg',
      });
      expect(v.youtubeId, 'vidy:movie:315162');
      expect(v.provider, 'vidy');
      expect(v.mediaType, 'movie');
      expect(
        v.thumbnail,
        'https://image.tmdb.org/t/p/w500/1NqwE62Xvum27eRPi4QVod7YWoG.jpg',
      );
    });

    test('PlayerAction.fromJson', () {
      final a = PlayerAction.fromJson({'type': 'seek', 'seconds': 25});
      expect(a!.type, ActionType.seek);
      expect(a.seconds, 25);
      expect(PlayerAction.fromJson({'type': 'rm -rf'}), isNull);
      expect(PlayerAction.fromJson(null), isNull);
    });
  });

  group('PlayerHandle', () {
    test('queues commands until attached and validates ids', () {
      final h = PlayerHandle();
      final t = RecordingTransport();
      h.load('not valid');
      h.load('aaaaaaaaaaa');
      h.seekBy(double.infinity);
      expect(t.calls, isEmpty);
      h.attach(t);
      expect(t.calls, ['load:aaaaaaaaaaa']);
      h.load('vidy:movie:315162');
      expect(t.calls.last, 'load:vidy:movie:315162');
      h.seekBy(25);
      h.stop();
      expect(t.calls.last, 'stop');
      expect(t.calls, contains('seekBy:25.0'));
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

    test(
      'topic reply suggests videos without playing; play, forward, stop',
      () async {
        final chat = c.read(chatProvider.notifier);
        api.onChat = (b) => {
          'conversation_id': 'c1',
          'reply': 'Here you go',
          'videos': [
            _video('aaaaaaaaaaa', 'Sourdough'),
            _video('bbbbbbbbbbb', 'Pasta'),
          ],
          'recommendations': [
            _video('bbbbbbbbbbb', 'Pasta'),
            _video('rrrrrrrrrrr', 'Related'),
          ],
          'action': null,
          'source': 'catalog',
        };
        await chat.send('sourdough bread');
        // Nothing starts on its own: the user picks from the suggestions.
        expect(c.read(chatProvider).nowPlaying, isNull);
        expect(transport.calls, isEmpty);
        chat.play(c.read(chatProvider).messages.last.videos.first);
        expect(c.read(chatProvider).nowPlaying?.youtubeId, 'aaaaaaaaaaa');
        expect(transport.calls, contains('load:aaaaaaaaaaa'));
        expect(
          [for (final v in c.read(chatProvider).rail) v.youtubeId],
          ['bbbbbbbbbbb', 'rrrrrrrrrrr'],
        );

        api.onChat = (b) => {
          'conversation_id': 'c1',
          'reply': 'Forward 25 seconds.',
          'videos': [],
          'action': {'type': 'seek', 'seconds': 25},
          'source': 'command',
        };
        await chat.send('forward 25 sec');
        expect(api.sent.last['player_open'], isTrue);
        expect(api.sent.last['conversation_id'], 'c1');
        expect(transport.calls.last, 'seekBy:25.0');
        expect(c.read(chatProvider).playerOpen, isTrue);

        c
            .read(playerHandleProvider)
            .emit(const PlayerEvent('time', t: 135, d: 600, playing: true));
        api.onChat = (b) => {
          'conversation_id': 'c1',
          'reply': 'Stopped.',
          'videos': [],
          'action': {'type': 'stop'},
          'source': 'command',
        };
        await chat.send('stop');
        expect(c.read(chatProvider).playerOpen, isFalse);
        expect(
          c.read(chatProvider).messages.last.text,
          'Stopped at 2:15. Back to chat.',
        );
        expect(transport.calls.last, 'stop');
      },
    );

    test('next plays the top recommendation', () async {
      final chat = c.read(chatProvider.notifier);
      api.onChat = (b) => {
        'conversation_id': 'c1',
        'reply': 'Here you go',
        'videos': [_video('aaaaaaaaaaa', 'A')],
        'recommendations': [_video('rrrrrrrrrrr', 'Related')],
        'source': 'catalog',
      };
      await chat.send('a');
      chat.play(c.read(chatProvider).messages.last.videos.first);
      chat.next();
      expect(c.read(chatProvider).nowPlaying?.youtubeId, 'rrrrrrrrrrr');
    });

    test('network errors surface without adding a reply', () async {
      api.onChat = (_) => throw ApiException('Can’t reach the server.');
      await c.read(chatProvider.notifier).send('hello');
      final s = c.read(chatProvider);
      expect(s.error, 'Can’t reach the server.');
      expect(s.sending, isFalse);
      expect(s.messages.length, 1);
    });
  });

  group('responsive', () {
    for (final size in const [Size(360, 740), Size(1440, 900)]) {
      testWidgets('login renders without overflow at ${size.width}px', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiProvider.overrideWithValue(FakeApi())],
            child: ShadApp(theme: lightTheme(), home: const LoginScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Welcome back'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('Try the demo signs in with a demo user', (tester) async {
    final api = FakeApi();
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(theme: lightTheme(), home: const LoginScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Try the demo'));
    await tester.tap(find.text('Try the demo'));
    await tester.pumpAndSettle();
    expect(api.demoCalls, 1);
    final auth = container.read(authProvider);
    expect(auth.status, AuthStatus.signedIn);
    expect(auth.user!.isDemo, isTrue);
  });

  group('/demo link', () {
    Future<(ProviderContainer, FakeApi)> boot(
      WidgetTester tester, {
      Map<String, dynamic>? session,
    }) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = FakeApi(session: session);
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const OttAiApp(),
        ),
      );
      await tester.pumpAndSettle();
      container.read(routerProvider).go('/demo');
      await tester.pumpAndSettle();
      return (container, api);
    }

    testWidgets(
      'signed-out visitor gets a demo session and lands in the chat',
      (tester) async {
        final (c, api) = await boot(tester);
        expect(api.demoCalls, 1);
        expect(c.read(authProvider).user!.isDemo, isTrue);
        expect(find.byType(ChatScreen), findsOneWidget);
        expect(find.text('Demo'), findsOneWidget);
      },
    );

    testWidgets(
      'already signed-in user goes straight to the chat, no demo created',
      (tester) async {
        final (c, api) = await boot(
          tester,
          session: {
            'access_token': 't',
            'user': {
              'id': 'u2',
              'email': 'me@example.com',
              'is_admin': false,
              'is_demo': false,
            },
          },
        );
        expect(api.demoCalls, 0);
        expect(find.byType(ChatScreen), findsOneWidget);
        expect(find.text('Demo'), findsNothing);
      },
    );
  });
}
