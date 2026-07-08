/// Result returned from a speech-to-text transcription request.
class TranscriptionResult {
  /// The recognised text.
  final String transcript;

  /// Model confidence in [0, 1], if provided by the API.
  final double? confidence;

  /// BCP-47 language code detected by the model (e.g. "si-lk").
  final String? detectedLanguage;

  const TranscriptionResult({
    required this.transcript,
    this.confidence,
    this.detectedLanguage,
  });
}
