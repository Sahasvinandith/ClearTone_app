import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'cache/audio_cache.dart';
import 'exceptions.dart';
import 'google_speech_client.dart';
import 'phone_speaker_router.dart';
import 'speech_config.dart';

/// Online Text-to-Speech service backed by Google Cloud TTS V1.
///
/// Synthesised audio is cached locally by text+voice key so repeated
/// requests skip the network round-trip.
class GcpTtsService {
  final GoogleSpeechClient _client;
  final TtsAudioCache _cache;
  final AudioPlayer _player = AudioPlayer();

  String _localeId = 'en-US';
  bool _isSpeaking = false;

  GcpTtsService(this._client, this._cache) {
    _player.onPlayerComplete.listen((_) {
      _isSpeaking = false;
      PhoneSpeakerRouter.resetAfterTts();
    });
  }

  bool get isSpeaking => _isSpeaking;

  /// Change the synthesis language / voice.
  void setLanguage(String localeId) => _localeId = localeId;

  /// Synthesises [text] in the current language and plays it immediately.
  ///
  /// Returns when playback starts (not when it finishes).
  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const SpeechUnknownException('Text is empty.');

    final voiceName =
        SpeechConfig.voiceMap[_localeId] ?? SpeechConfig.voiceMap['en-US']!;

    Uint8List? audioBytes = await _cache.get(trimmed, voiceName);

    if (audioBytes == null) {
      debugPrint('[GcpTTS] Cache miss — synthesising via API...');
      audioBytes = await _client.synthesize(trimmed, _localeId);
      await _cache.put(trimmed, voiceName, audioBytes);
      debugPrint(
        '[GcpTTS] Cached ${audioBytes.length} bytes for voice=$voiceName',
      );
    } else {
      debugPrint('[GcpTTS] Cache hit for voice=$voiceName');
    }

    await PhoneSpeakerRouter.enableForTts();
    await _player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          audioMode: AndroidAudioMode.inCommunication,
          stayAwake: true,
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.voiceCommunication,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ),
    );
    await _player.stop(); // cancel any previous playback
    _isSpeaking = true;
    await _player.play(BytesSource(audioBytes));
  }

  Future<void> stop() async {
    await _player.stop();
    await PhoneSpeakerRouter.resetAfterTts();
    _isSpeaking = false;
  }

  Future<void> pause() => _player.pause();

  Future<void> resume() => _player.resume();

  void dispose() => _player.dispose();
}
