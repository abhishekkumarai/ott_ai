import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Coral on warm paper, from the Stitch "Chat-first with Mini-player" screens
// (design.md §1). Everything reads colors from ShadTheme; the few extra roles the
// shadcn scheme has no slot for live here as constants.

/// Brand coral: primary buttons, send, play, progress, live dot.
const coral = Color(0xFFFF5A3D);

/// Coral for text on light surfaces (links, active tab, timestamps) — AA contrast.
const coralText = Color(0xFFB5250E);

/// Soft coral fill ("Now playing" pill, current chapter row) and its border.
const coralSoft = Color(0xFFFFDAD3);
const coralSoftBorder = Color(0xFFFFB4A5);

/// Positive badges ("Matched in 0.8s", "% match").
const success = Color(0xFF406840);
const successSoft = Color(0xFFC1EEBC);

/// Playback progress, the listening mic and other "live" indicators.
const accent = coral;

const fontSans = 'Plus Jakarta Sans';
const fontMono = 'JetBrains Mono';

/// Timecodes, quality labels and keyboard hints.
TextStyle mono(BuildContext context, {double size = 12, Color? color}) =>
    TextStyle(
      fontFamily: fontMono,
      fontSize: size,
      fontWeight: FontWeight.w500,
      letterSpacing: .2,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: color ?? ShadTheme.of(context).colorScheme.mutedForeground,
    );

final _pill = BorderRadius.circular(999);

ShadThemeData _base(Brightness brightness, ShadColorScheme cs) => ShadThemeData(
  brightness: brightness,
  colorScheme: cs,
  radius: BorderRadius.circular(12),
  textTheme: ShadTextTheme(family: fontSans),
  // Buttons and chips are pills in the design; inputs keep the 12px radius.
  primaryButtonTheme: ShadButtonTheme(
    decoration: ShadDecoration(border: ShadBorder.all(radius: _pill)),
  ),
  secondaryButtonTheme: ShadButtonTheme(
    decoration: ShadDecoration(border: ShadBorder.all(radius: _pill)),
  ),
  // Neutral text on outline/ghost buttons; coral is kept for primary actions.
  outlineButtonTheme: ShadButtonTheme(
    foregroundColor: cs.foreground,
    hoverForegroundColor: cs.foreground,
    decoration: ShadDecoration(border: ShadBorder.all(radius: _pill)),
  ),
  ghostButtonTheme: ShadButtonTheme(
    foregroundColor: cs.foreground,
    hoverForegroundColor: cs.foreground,
  ),
  destructiveButtonTheme: ShadButtonTheme(
    decoration: ShadDecoration(border: ShadBorder.all(radius: _pill)),
  ),
);

ShadThemeData lightTheme() => _base(
  Brightness.light,
  const ShadColorScheme(
    background: Color(0xFFF9F9F6),
    foreground: Color(0xFF1A1C1B),
    card: Color(0xFFFFFFFF),
    cardForeground: Color(0xFF1A1C1B),
    popover: Color(0xFFFFFFFF),
    popoverForeground: Color(0xFF1A1C1B),
    primary: coral,
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFFEEEEEB),
    secondaryForeground: Color(0xFF1A1C1B),
    muted: Color(0xFFEEEEEB),
    mutedForeground: Color(0xFF6E5A55),
    accent: Color(0xFFE8E8E5),
    accentForeground: Color(0xFF1A1C1B),
    destructive: Color(0xFFBA1A1A),
    destructiveForeground: Color(0xFFFFFFFF),
    border: Color(0xFFE6DAD6),
    input: Color(0xFFE3BEB7),
    ring: coral,
    selection: coralSoft,
  ),
);

/// Warm dark variant for the Appearance setting (OTTAI-14); same coral accent.
ShadThemeData darkTheme() => _base(
  Brightness.dark,
  const ShadColorScheme(
    background: Color(0xFF1A1716),
    foreground: Color(0xFFF1EDEA),
    card: Color(0xFF231F1E),
    cardForeground: Color(0xFFF1EDEA),
    popover: Color(0xFF262120),
    popoverForeground: Color(0xFFF1EDEA),
    primary: coral,
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFF2E2826),
    secondaryForeground: Color(0xFFF1EDEA),
    muted: Color(0xFF2E2826),
    mutedForeground: Color(0xFFB3A6A1),
    accent: Color(0xFF3A3230),
    accentForeground: Color(0xFFF1EDEA),
    destructive: Color(0xFFFF8A80),
    destructiveForeground: Color(0xFF2B0000),
    border: Color(0xFF3A3230),
    input: Color(0xFF4A3F3C),
    ring: coral,
    selection: Color(0xFF6E2A1C),
  ),
);

/// Coral text on either brightness (the light one is too dark on dark surfaces).
Color coralOn(BuildContext context) =>
    ShadTheme.of(context).brightness == Brightness.dark
    ? const Color(0xFFFF8A73)
    : coralText;

/// Soft coral fill on either brightness.
Color coralSoftOn(BuildContext context) =>
    ShadTheme.of(context).brightness == Brightness.dark
    ? const Color(0x33FF5A3D)
    : coralSoft;

const contentMaxWidth = 760.0;

// Layout breakpoints (logical px of the whole window).
/// Below this: phone layout (top bar + slide-in sheets, no side column).
const mobileBreakpoint = 720.0;

/// At/above this the left navigation shows labels; between mobile and this it is an icon rail.
const navExpandedBreakpoint = 1100.0;

const navExpandedWidth = 272.0;
const navRailWidth = 68.0;

/// Floating mini-player card width (desktop); phones use the column width.
const miniPlayerWidth = 420.0;
