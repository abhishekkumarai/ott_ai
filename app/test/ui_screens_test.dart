// Renders the main screens at several viewport sizes with the real fonts, fails on
// any layout overflow, and writes PNG snapshots to test/goldens/ for visual review.
//
//   flutter test test/ui_screens_test.dart --update-goldens

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ott_ai/auth/auth.dart';
import 'package:ott_ai/chat/chat_controller.dart';
import 'package:ott_ai/chat/chat_screen.dart';
import 'package:ott_ai/settings/preferences.dart';
import 'package:ott_ai/theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'widget_test.dart' show FakeApi;

Map<String, dynamic> _v(String id, String title, String channel) => {
  'youtube_id': id,
  'title': title,
  'channel': channel,
  'duration_s': 612,
  'topic': 'astronomy',
  'match': 93 - title.length % 7,
};

final _videos = [
  _v(
    'aaaaaaaaaaa',
    'Black Holes Explained – From Birth to Death',
    'Kurzgesagt – In a Nutshell',
  ),
  _v(
    'bbbbbbbbbbb',
    'What Happens Inside a Black Hole? A very long title that should wrap nicely',
    'PBS Space Time',
  ),
  _v(
    'ccccccccccc',
    'Quantum Mechanics Explained in Ridiculously Simple Words',
    'Science ABC',
  ),
  _v('ddddddddddd', 'How Stars Die', 'Crash Course'),
];

class ScreenApi extends FakeApi {
  ScreenApi()
    : super(
        session: {
          'access_token': 't',
          'user': {
            'id': 'u',
            'email': 'demo-1a2b3c@demo.invalid',
            'is_admin': false,
            'is_demo': true,
          },
        },
      );

  @override
  Future<dynamic> get(String path, [Map<String, dynamic>? query]) async {
    if (path == '/models') {
      return {
        'models': ['llama3.2:3b', 'qwen3.5:4b'],
        'default': 'llama3.2:3b',
      };
    }
    if (path == '/me/preferences') return <String, dynamic>{};
    if (path.endsWith('/recommendations')) return _videos.sublist(1);
    if (path.endsWith('/chapters')) {
      return [
        {'start_s': 0, 'title': 'Intro: what a black hole is'},
        {'start_s': 75, 'title': 'Stars collapsing under their own gravity'},
        {
          'start_s': 220,
          'title': 'The event horizon and why light can’t escape',
        },
        {'start_s': 380, 'title': 'Supermassive black holes at galaxy centres'},
      ];
    }
    if (path == '/conversations') {
      return [
        for (final (i, t) in [
          'How do black holes form?',
          'Sourdough bread for beginners',
          'Learn basic guitar chords',
        ].indexed)
          {
            'id': 'c$i',
            'title': t,
            'updated_at': DateTime.now()
                .subtract(Duration(days: i))
                .toIso8601String(),
          },
      ];
    }
    return [];
  }
}

Future<void> _loadFonts() async {
  final manifest =
      json.decode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final f in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(Uri.decodeFull(f['asset'] as String)));
    }
    await loader.load();
  }
}

const sizes = {
  'desktop': Size(1440, 900),
  'laptop-short': Size(1280, 620),
  'tablet': Size(900, 1000),
  'phone': Size(390, 844),
};

void main() {
  setUpAll(_loadFonts);

  for (final MapEntry(key: name, value: size) in sizes.entries) {
    for (final scenario in ['empty', 'chat', 'playing', 'mini']) {
      testWidgets('$scenario @ $name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final api = ScreenApi()
          ..onChat = (b) => {
            'conversation_id': 'c0',
            'reply':
                'Here are a few clear explainers on how black holes form, from collapsing stars '
                'to supermassive ones at the centre of galaxies.',
            'videos': _videos,
            'highlights': ['collapsing stars'],
            'action': null,
            'source': 'catalog',
          };
        final container = ProviderContainer(
          overrides: [
            apiProvider.overrideWithValue(api),
            playerViewBuilderProvider.overrideWithValue(
              (_) => const ColoredBox(
                color: Color(0xFF18181B),
                child: Center(child: Text('▶ video')),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authProvider.notifier).startDemo();

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: ShadApp(theme: lightTheme(), home: const ChatScreen()),
          ),
        );
        await tester.pumpAndSettle();

        final chat = container.read(chatProvider.notifier);
        if (scenario != 'empty') {
          await chat.send('show me how black holes form');
          await tester.pumpAndSettle();
          // Replies don't autoplay; "chat" shows the suggestions as they arrive.
          if (scenario != 'chat') {
            chat.play(container.read(chatProvider).messages.last.videos.first);
            await tester.pumpAndSettle();
            container
                .read(playbackProvider.notifier)
                .set(const Playback(t: 83, d: 612, playing: true));
            if (scenario == 'playing') {
              container
                  .read(playerModeProvider.notifier)
                  .set(PlayerMode.theater);
            }
          }
          await tester.pumpAndSettle();
        }

        expect(
          tester.takeException(),
          isNull,
          reason: 'layout overflow in $scenario @ $name',
        );
        await expectLater(
          find.byType(ChatScreen),
          matchesGoldenFile('goldens/$scenario-$name.png'),
        );
      });
    }
  }

  testWidgets(
    'Scroll to top appears away from the first message and goes there',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = ScreenApi()
        ..onChat = (b) => {
          'conversation_id': 'c0',
          'reply': 'Here are some videos.',
          'videos': _videos,
          'action': null,
          'source': 'catalog',
        };
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).startDemo();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ShadApp(theme: lightTheme(), home: const ChatScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final chat = container.read(chatProvider.notifier);
      for (var i = 0; i < 6; i++) {
        await chat.send('black holes $i');
        await tester.pumpAndSettle();
      }

      IgnorePointer gate() => tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byIcon(LucideIcons.arrowUpToLine),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      final list = tester
          .state<ScrollableState>(
            // The chat list is the reversed (bottom-up) one.
            find.byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.up,
            ),
          )
          .position;

      // At the latest message: hidden and untappable.
      expect(gate().ignoring, isTrue);

      list.jumpTo(list.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      expect(gate().ignoring, isFalse);

      await tester.tap(find.byIcon(LucideIcons.arrowUpToLine));
      await tester.pumpAndSettle();
      expect(list.extentAfter, 0);
      expect(find.text('black holes 0'), findsOneWidget);
      expect(gate().ignoring, isTrue);
    },
  );
}
