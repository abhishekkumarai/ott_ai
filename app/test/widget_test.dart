import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reel/api/api.dart';
import 'package:reel/auth/auth.dart';
import 'package:reel/auth/login_screen.dart';
import 'package:reel/chat/chat_controller.dart';
import 'package:reel/chat/models.dart';
import 'package:reel/player/player_handle.dart';
import 'package:reel/theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Fake backend: canned /chat replies, no network.
class FakeApi extends ApiClient {
  final sent = <Map<String, dynamic>>[];
  Map<String, dynamic> Function(Map<String, dynamic> body)? onChat;

  @override
  Future<Map<String, dynamic>?> refresh() async => null;

  @override
  Future<dynamic> get(String path, [Map<String, dynamic>? query]) async {
    if (path == '/models') return {'models': ['llama3.2:3b', 'qwen3.5:4b'], 'default': 'llama3.2:3b'};
    if (path.endsWith('/recommendations')) return [_video('rrrrrrrrrrr', 'Related')];
    return [];
  }

  @override
  Future<dynamic> post(String path, [Object? body]) async {
    if (path == '/chat') {
      final b = Map<String, dynamic>.from(body as Map);
      sent.add(b);
      return onChat!(b);
    }
    return null;
  }
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
  void send(String cmd, {String? id, double? start, double? seconds}) =>
      calls.add([cmd, ?id, ?seconds].join(':'));
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
      expect(() => Video.fromJson(_video('bad"id', 'x')), throwsFormatException);
      final v = Video.fromJson({..._video('aaaaaaaaaaa', 'x'), 'thumbnail': 'javascript:alert(1)'});
      expect(v.thumbnail, 'https://i.ytimg.com/vi/aaaaaaaaaaa/mqdefault.jpg');
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

    test('topic reply opens the first video; forward keeps playing; stop closes', () async {
      final chat = c.read(chatProvider.notifier);
      api.onChat = (b) => {
            'conversation_id': 'c1',
            'reply': 'Here you go',
            'videos': [_video('aaaaaaaaaaa', 'Sourdough'), _video('bbbbbbbbbbb', 'Pasta')],
            'action': null,
            'source': 'catalog',
          };
      await chat.send('sourdough bread');
      expect(c.read(chatProvider).nowPlaying?.youtubeId, 'aaaaaaaaaaa');
      expect(transport.calls, contains('load:aaaaaaaaaaa'));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(chatProvider).recommendations.single.youtubeId, 'rrrrrrrrrrr');

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

      c.read(playerHandleProvider).emit(const PlayerEvent('time', t: 135, d: 600, playing: true));
      api.onChat = (b) => {
            'conversation_id': 'c1',
            'reply': 'Stopped.',
            'videos': [],
            'action': {'type': 'stop'},
            'source': 'command',
          };
      await chat.send('stop');
      expect(c.read(chatProvider).playerOpen, isFalse);
      expect(c.read(chatProvider).messages.last.text, 'Stopped at 2:15. Back to chat.');
      expect(transport.calls.last, 'stop');
    });

    test('next plays the first recommendation', () async {
      final chat = c.read(chatProvider.notifier);
      chat.play(Video.fromJson(_video('aaaaaaaaaaa', 'A')));
      await Future<void>.delayed(Duration.zero);
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
      testWidgets('login renders without overflow at ${size.width}px', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          overrides: [apiProvider.overrideWithValue(FakeApi())],
          child: ShadApp(theme: lightTheme(), home: const LoginScreen()),
        ));
        await tester.pumpAndSettle();
        expect(find.text('Welcome back'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
