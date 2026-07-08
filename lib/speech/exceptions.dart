/// Base class for all speech-related exceptions.
abstract class SpeechException implements Exception {
  final String message;
  const SpeechException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when the microphone permission is denied.
class SpeechPermissionDeniedException extends SpeechException {
  const SpeechPermissionDeniedException()
      : super('Microphone permission denied.');
}

/// Thrown when the API key is missing or rejected.
class SpeechAuthenticationException extends SpeechException {
  const SpeechAuthenticationException([
    super.message = 'Invalid or missing Google Cloud API key.',
  ]);
}

/// Thrown on network-level failures (no connectivity, DNS errors, etc.).
class SpeechNetworkException extends SpeechException {
  const SpeechNetworkException([super.message = 'Network error.']);
}

/// Thrown when the HTTP request exceeds the configured timeout.
class SpeechTimeoutException extends SpeechException {
  const SpeechTimeoutException() : super('Request timed out.');
}

/// Thrown when the GCP quota for the API is exceeded.
class SpeechQuotaExceededException extends SpeechException {
  const SpeechQuotaExceededException() : super('API quota exceeded.');
}

/// Thrown when the requested locale is not supported.
class SpeechUnsupportedLanguageException extends SpeechException {
  const SpeechUnsupportedLanguageException(String locale)
      : super('Unsupported language: $locale');
}

/// Thrown for unexpected / unclassified errors.
class SpeechUnknownException extends SpeechException {
  const SpeechUnknownException([super.message = 'Unknown error.']);
}
