import 'cache/audio_cache.dart';
import 'google_speech_client.dart';
import 'stt_service.dart';
import 'tts_service.dart';

/// Facade that wires together [GcpSttService] and [GcpTtsService]
/// via a shared [GoogleSpeechClient].
///
/// Create one instance per screen and call [dispose] when done.
class SpeechService {
  final GoogleSpeechClient _client;
  final TtsAudioCache _cache;

  late final GcpSttService stt;
  late final GcpTtsService tts;

  SpeechService()
      : _client = GoogleSpeechClient(),
        _cache = TtsAudioCache() {
    stt = GcpSttService(_client);
    tts = GcpTtsService(_client, _cache);
  }

  /// Propagates the language change to both STT and TTS services.
  void setLanguage(String localeId) {
    stt.setLanguage(localeId);
    tts.setLanguage(localeId);
  }

  void dispose() {
    stt.dispose();
    tts.dispose();
    _client.dispose();
  }
}
