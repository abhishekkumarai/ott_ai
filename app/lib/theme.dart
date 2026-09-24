import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// shadcn "zinc" with a single restrained accent used only for playback progress.
const accent = Color(0xFFEA580C);

ShadThemeData lightTheme() => ShadThemeData(
      brightness: Brightness.light,
      colorScheme: const ShadZincColorScheme.light(),
      radius: BorderRadius.circular(8),
    );

ShadThemeData darkTheme() => ShadThemeData(
      brightness: Brightness.dark,
      colorScheme: const ShadZincColorScheme.dark(),
      radius: BorderRadius.circular(8),
    );

/// Width at which the player shows recommendations in a side panel.
const wideBreakpoint = 1024.0;
const contentMaxWidth = 720.0;
