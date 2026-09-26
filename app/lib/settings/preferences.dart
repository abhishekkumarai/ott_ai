import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api.dart';
import '../auth/auth.dart';

enum PlayerMode { mini, theater }

const playbackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// Voice recognition languages offered in Settings (BCP-47, as the backend validates).
const voiceLanguages = {
  'en-US': 'English (US)',
  'en-GB': 'English (UK)',
  'en-IN': 'English (India)',
  'hi-IN': 'Hindi',
  'es-ES': 'Spanish',
  'fr-FR': 'French',
  'de-DE': 'German',
};

/// Per-user settings, stored server-side (`/api/me/preferences`) so they follow the
/// user across devices. Demo users get the same, deleted with the demo account.
class Preferences {
  const Preferences({
    this.model,
    this.playerMode = PlayerMode.mini,
    this.autoplayNext = false,
    this.playbackRate = 1.0,
    this.startMuted = false,
    this.voiceEnabled = true,
    this.voiceLanguage = 'en-US',
    this.appearance = ThemeMode.light,
  });

  final String? model;
  final PlayerMode playerMode;
  final bool autoplayNext;
  final double playbackRate;
  final bool startMuted;
  final bool voiceEnabled;
  final String voiceLanguage;
  final ThemeMode appearance;

  factory Preferences.fromJson(Map<String, dynamic> j) => Preferences(
    model: j['model'] as String?,
    playerMode: j['player_mode'] == 'theater'
        ? PlayerMode.theater
        : PlayerMode.mini,
    autoplayNext: j['autoplay_next'] == true,
    playbackRate: (j['playback_rate'] as num?)?.toDouble() ?? 1.0,
    startMuted: j['start_muted'] == true,
    voiceEnabled: j['voice_enabled'] != false,
    voiceLanguage: j['voice_language'] as String? ?? 'en-US',
    appearance: switch (j['appearance']) {
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.light,
    },
  );

  static String appearanceName(ThemeMode m) => switch (m) {
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
    ThemeMode.light => 'light',
  };
}

class PreferencesController extends Notifier<Preferences> {
  @override
  Preferences build() {
    // Reload whenever a different user signs in.
    final userId = ref.watch(authProvider.select((a) => a.user?.id));
    if (userId != null) Future.microtask(_load);
    return const Preferences();
  }

  ApiClient get _api => ref.read(apiProvider);

  Future<void> _load() async {
    try {
      final data = await _api.get('/me/preferences');
      if (!ref.mounted) return;
      state = Preferences.fromJson(Map<String, dynamic>.from(data as Map));
    } on ApiException {
      // Offline or an older server: keep defaults.
    }
  }

  /// Optimistic update; reverts and rethrows if the server rejects it.
  Future<void> update(Map<String, Object?> patch) async {
    final previous = state;
    final merged = <String, dynamic>{..._toJson(state), ...patch};
    state = Preferences.fromJson(merged);
    try {
      final data = await _api.patch('/me/preferences', patch);
      if (!ref.mounted) return;
      state = Preferences.fromJson(Map<String, dynamic>.from(data as Map));
    } on ApiException {
      state = previous;
      rethrow;
    }
  }

  static Map<String, Object?> _toJson(Preferences p) => {
    'model': p.model,
    'player_mode': p.playerMode.name,
    'autoplay_next': p.autoplayNext,
    'playback_rate': p.playbackRate,
    'start_muted': p.startMuted,
    'voice_enabled': p.voiceEnabled,
    'voice_language': p.voiceLanguage,
    'appearance': Preferences.appearanceName(p.appearance),
  };
}

final preferencesProvider =
    NotifierProvider<PreferencesController, Preferences>(
      PreferencesController.new,
    );
