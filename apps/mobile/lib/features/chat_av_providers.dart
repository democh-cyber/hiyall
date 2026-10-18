import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat/chat_play_files.dart';
import '../core/chat/chat_recorder.dart';
import '../core/chat/chat_video_prep.dart';
import '../core/chat/chat_voice_player.dart';
import '../core/translate/speech_service.dart';
import '../core/translate/translation_memory.dart';
import '../core/translate/translation_mlkit.dart';
import '../core/translate/translation_service.dart';
import 'chat.dart' show chatEngineProvider;

// The platform pieces of voice messages, videos, translation and reading aloud, each behind an interface and
// each replaceable in tests (a fake recorder, a fake player, a fake translator, a fake voice).

/// The microphone. The real one needs a phone.
final voiceRecorderProvider = Provider<VoiceRecorder>((ref) {
  final recorder = RecordVoiceRecorder();
  ref.onDispose(recorder.dispose);
  return recorder;
});

/// Makes the audio player of a voice message. The real one needs a phone.
final voicePlayerFactoryProvider = Provider<VoicePlayer Function()>(
  (_) => JustAudioVoicePlayer.new,
);

/// Where short-lived plaintext may be written: the engine's own `chat_play` folder (a fallback only for
/// tests that have no engine).
final playFilesProvider = Provider<PlayFiles>((ref) {
  final engine = ref.watch(chatEngineProvider).asData?.value;
  return engine?.playFiles ??
      PlayFiles(Directory('${Directory.systemTemp.path}/hiyall_chat_play'));
});

/// The one voice message that plays at a time.
final voicePlaybackProvider = Provider<VoicePlayback>((ref) {
  final playback = VoicePlayback(
    makePlayer: ref.watch(voicePlayerFactoryProvider),
    files: ref.watch(playFilesProvider),
  );
  ref.onDispose(playback.dispose);
  return playback;
});

/// Turns a picked video into what is sent; null where the chat has no media folder.
final videoPreparerProvider = Provider<VideoPreparer?>((ref) {
  final engine = ref.watch(chatEngineProvider).asData?.value;
  final files = engine?.playFiles;
  if (engine == null || files == null) return null;
  return ProVideoPreparer(codec: engine.blobCodec, files: files);
});

/// On-device translation (see lib/core/translate). Nothing is sent to a server.
final translationServiceProvider = Provider<TranslationService>((ref) {
  final service = MlKitTranslationService();
  ref.onDispose(service.dispose);
  return service;
});

/// On-device reading aloud.
final speechServiceProvider = Provider<SpeechService>((ref) {
  final service = DeviceSpeechService();
  ref.onDispose(service.dispose);
  return service;
});

/// Translations already shown, in memory only; a new engine (another account) starts with none.
final translationMemoryProvider = Provider<TranslationMemory>((ref) {
  ref.watch(chatEngineProvider);
  return TranslationMemory();
});
