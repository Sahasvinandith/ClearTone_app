/// Centralized configuration for Google Cloud Speech APIs.
class SpeechConfig {
  const SpeechConfig._();

  // ---- STT ----
  static const String sttModel = 'chirp_2';
  static const String sttLocation = 'asia-southeast1';

  static const List<String> supportedLocales = [
    'si-LK',
    'ta-LK',
    'ta-IN',
    'en-IN',
    'en-US',
  ];

  // ---- TTS ----
  static const Map<String, String> voiceMap = {
    'si-LK': 'si-LK-Standard-A',
    'ta-LK': 'ta-LK-Wavenet-A',
    'ta-IN': 'ta-IN-Neural2-B',
    'en-IN': 'en-IN-Neural2-B',
    'en-US': 'en-US-Neural2-J',
  };

  static const String ttsAudioEncoding = 'MP3';
  static const int ttsSampleRate = 24000;

  // ---- HTTP ----
  static const int httpTimeoutSeconds = 30;
}
