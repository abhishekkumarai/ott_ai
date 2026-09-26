import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../chat/chat_controller.dart';
import '../settings/preferences.dart';
import '../theme.dart';

bool get _apple =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// "⌘K" on Apple platforms, "Ctrl+K" elsewhere.
String shortcutLabel(String key) => _apple ? '⌘$key' : 'Ctrl+$key';

/// Focus target for ⌘K (the top bar search box registers itself here).
final searchFocusProvider = Provider<FocusNode>((ref) {
  final n = FocusNode(debugLabel: 'global-search');
  ref.onDispose(n.dispose);
  return n;
});

/// The one list the dialog, README and composer hint are written from (OTTAI-12).
List<(String, String)> shortcutList() => [
  ('Space', 'Play / pause'),
  ('M', 'Mute / unmute'),
  ('← / →', 'Back / forward ${seekStep.round()} s'),
  ('N', 'Next video'),
  ('I', 'Mini player'),
  ('T', 'Theater mode'),
  if (canFullscreen) ('F', 'Fullscreen (Esc to leave)'),
  ('Esc', 'Stop the video'),
  (shortcutLabel('K'), 'Search chats and videos'),
  (shortcutLabel('N'), 'New discovery session'),
  ('?', 'Show this list'),
];

void showShortcutsDialog(BuildContext context) {
  showShadDialog(
    context: context,
    builder: (ctx) {
      final theme = ShadTheme.of(ctx);
      return ShadDialog(
        title: const Text('Keyboard shortcuts'),
        description: const Text(
          'Player keys work when you’re not typing. In an empty message box, '
          '← / → still seek and Esc still stops.',
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (keys, action) in shortcutList())
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(action, style: theme.textTheme.small)),
                    ShadBadge.outline(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 1,
                      ),
                      child: Text(keys, style: mono(ctx, size: 12)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// App-wide keyboard handling for the chat screen. Registered with
/// [HardwareKeyboard] so it works wherever focus is, but never steals keys from
/// a text field (the composer handles its own ←/→/Esc when empty).
class GlobalShortcuts extends ConsumerStatefulWidget {
  const GlobalShortcuts({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends ConsumerState<GlobalShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Nothing in particular has focus (e.g. after clicking the page). Only then do
  /// Space / Esc / arrows drive the player; otherwise they belong to the focused
  /// button, dropdown or popover.
  bool get _nothingFocused {
    final f = FocusManager.instance.primaryFocus;
    return f == null || f is FocusScopeNode;
  }

  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    // Not while a dialog/sheet or another page is on top.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final kb = HardwareKeyboard.instance;
    final cmd = _apple ? kb.isMetaPressed : kb.isControlPressed;
    final key = e.logicalKey;
    final chat = ref.read(chatProvider.notifier);

    if (cmd && key == LogicalKeyboardKey.keyK) {
      ref.read(searchFocusProvider).requestFocus();
      return true;
    }
    if (cmd && key == LogicalKeyboardKey.keyN) {
      chat.newChat();
      return true;
    }
    if (cmd || kb.isAltPressed || _typing) return false;

    if (e.character == '?') {
      showShortcutsDialog(context);
      return true;
    }
    if (!ref.read(chatProvider).playerOpen) return false;
    final mode = ref.read(playerModeProvider.notifier);
    final navKeys = {
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    };
    if (navKeys.contains(key) && !_nothingFocused) return false;
    final action = switch (key) {
      LogicalKeyboardKey.space || LogicalKeyboardKey.keyK => chat.togglePause,
      LogicalKeyboardKey.keyM => chat.toggleMute,
      LogicalKeyboardKey.arrowRight => () => chat.forward(seekStep),
      LogicalKeyboardKey.arrowLeft => () => chat.back(seekStep),
      LogicalKeyboardKey.keyN => chat.next,
      LogicalKeyboardKey.keyI => () => mode.set(PlayerMode.mini),
      LogicalKeyboardKey.keyT => () => mode.set(PlayerMode.theater),
      LogicalKeyboardKey.keyF when canFullscreen => chat.fullscreen,
      LogicalKeyboardKey.escape => chat.stopFromUi,
      _ => null,
    };
    if (action == null) return false;
    action();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
