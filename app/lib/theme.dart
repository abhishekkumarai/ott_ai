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

const contentMaxWidth = 720.0;

// Layout breakpoints (logical px of the whole window).
/// Below this: phone layout (top bar + slide-in sheets, no side columns).
const mobileBreakpoint = 720.0;

/// At/above this the left navigation shows labels; between mobile and this it is an icon rail.
const navExpandedBreakpoint = 1360.0;

/// At/above this the right panel (history / up next) is always visible.
const rightPanelBreakpoint = 1024.0;

const navExpandedWidth = 248.0;
const navRailWidth = 68.0;
const rightPanelWidth = 336.0;
