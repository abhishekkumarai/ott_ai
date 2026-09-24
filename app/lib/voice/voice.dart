import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Push-to-talk speech recognition (browser Web Speech API on web, platform recognizer
/// on Android/Windows). Free; if the platform has no recognizer the mic is hidden.
class VoiceState {
  const VoiceState({this.available = false, this.listening = false, this.partial = ''});
  final bool available;
  final bool listening;
  final String partial;

  VoiceState copyWith({bool? available, bool? listening, String? partial}) => VoiceState(
        available: available ?? this.available,
        listening: listening ?? this.listening,
        partial: partial ?? this.partial,
      );
}

class VoiceController extends Notifier<VoiceState> {
  final _speech = SpeechToText();
  bool _initialized = false;
  void Function(String text)? _onFinal;

  @override
  VoiceState build() {
    Future.microtask(_init);
    return const VoiceState();
  }

  Future<void> _init() async {
    try {
      final ok = await _speech.initialize(
        onStatus: (s) {
          if (s == SpeechToText.doneStatus || s == SpeechToText.notListeningStatus) {
            state = state.copyWith(listening: false);
          }
        },
        onError: (e) => state = state.copyWith(listening: false, partial: ''),
      );
      _initialized = ok;
      state = state.copyWith(available: ok);
    } catch (e) {
      debugPrint('speech unavailable: $e');
      state = state.copyWith(available: false);
    }
  }

  Future<void> start(void Function(String text) onFinal) async {
    if (!_initialized || state.listening) return;
    _onFinal = onFinal;
    state = state.copyWith(listening: true, partial: '');
    await _speech.listen(
      onResult: (r) {
        state = state.copyWith(partial: r.recognizedWords);
        if (r.finalResult) {
          final text = r.recognizedWords.trim();
          state = state.copyWith(listening: false, partial: '');
          if (text.isNotEmpty) _onFinal?.call(text);
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> stop() async {
    if (state.listening) await _speech.stop();
  }
}

final voiceProvider = NotifierProvider<VoiceController, VoiceState>(VoiceController.new);
