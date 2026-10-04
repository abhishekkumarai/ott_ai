import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ott_ai/auth/auth.dart';
import 'package:ott_ai/chat/chat_controller.dart';
import 'package:ott_ai/chat/status_line.dart';
import 'package:ott_ai/settings/settings_screen.dart';
import 'package:ott_ai/theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'widget_test.dart' show FakeApi;

void main() {
  late ProviderContainer c;
  late FakeApi api;

  setUp(() {
    api = FakeApi();
    c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
  });
  tearDown(() => c.dispose());

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await c.read(authProvider.notifier).startDemo();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: ShadApp(
          theme: lightTheme(),
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Ollama health check in Settings', () {
    testWidgets('healthy status displays details and refreshes models', (
      tester,
    ) async {
      api.ollamaHealth = {
        'status': 'healthy',
        'ok': true,
        'version': '0.3.14',
        'models': ['llama3.2:3b', 'qwen3.5:4b', 'nomic-embed-text:latest'],
        'available_models': ['llama3.2:3b', 'qwen3.5:4b'],
        'installed_count': 3,
        'embed_model': 'nomic-embed-text:latest',
        'embed_available': true,
        'ollama_url': 'http://localhost:11434',
        'latency_ms': 14,
        'message': 'Ollama is running normally with 3 model(s) installed.',
      };

      await pump(tester, const SettingsScreen());
      expect(find.text('Ollama health'), findsOneWidget);
      expect(find.text('Check health'), findsOneWidget);

      await tester.tap(find.text('Check health'));
      await tester.pumpAndSettle();

      expect(api.gets, contains('/ollama/health'));
      expect(find.text('Healthy • 14ms'), findsOneWidget);
      expect(find.text('v0.3.14'), findsOneWidget);
      expect(find.text('http://localhost:11434'), findsOneWidget);
      expect(
        find.text('Ollama is running normally with 3 model(s) installed.'),
        findsWidgets,
      );
      expect(find.text('Installed models (3):'), findsOneWidget);
      expect(find.text('Re-check'), findsOneWidget);
    });

    testWidgets('unreachable status displays offline badge', (tester) async {
      api.ollamaHealth = {
        'status': 'unreachable',
        'ok': false,
        'version': null,
        'models': [],
        'available_models': [],
        'installed_count': 0,
        'embed_model': 'nomic-embed-text:latest',
        'embed_available': false,
        'ollama_url': 'http://localhost:11434',
        'latency_ms': null,
        'message': 'Could not connect to Ollama at http://localhost:11434.',
      };

      await pump(tester, const SettingsScreen());
      await tester.tap(find.text('Check health'));
      await tester.pumpAndSettle();

      expect(find.text('Offline / Unreachable'), findsOneWidget);
      expect(
        find.text('Could not connect to Ollama at http://localhost:11434.'),
        findsWidgets,
      );
    });
  });

  group('ModelSelectDropdown in chat input', () {
    testWidgets('shows current model and switches on select', (tester) async {
      await c.read(chatProvider.notifier).loadModels();
      expect(c.read(chatProvider).model, 'llama3.2:3b');

      await pump(tester, const ChatStatusLine());
      expect(find.text('llama3.2:3b'), findsOneWidget);

      // Open the dropdown
      await tester.tap(find.byType(ModelSelectDropdown));
      await tester.pumpAndSettle();

      // Options for both models should appear
      expect(find.text('qwen3.5:4b'), findsWidgets);

      // Select qwen3.5:4b
      await tester.tap(find.text('qwen3.5:4b').last);
      await tester.pumpAndSettle();

      expect(c.read(chatProvider).model, 'qwen3.5:4b');
    });
  });
}
