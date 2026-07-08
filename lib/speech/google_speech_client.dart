import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:http/http.dart' as http;

import 'exceptions.dart';
import 'speech_config.dart';
import 'speech_models.dart';

/// Low-level HTTP client for Google Cloud Speech-to-Text V2
/// and Text-to-Speech V1 REST APIs.
///
/// Authenticates via a service account JWT (OAuth2).
/// Never logs the private key or access tokens.
class GoogleSpeechClient {
  final String _projectId;

  /// Lazily-initialised authenticated HTTP client.
  gauth.AutoRefreshingAuthClient? _authClient;

  static const _scopes = ['https://www.googleapis.com/auth/cloud-platform'];

  GoogleSpeechClient() : _projectId = _readEnv('GOOGLE_CLOUD_PROJECT_ID');

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  static String _readEnv(String key) {
    final value = dotenv.env[key];
    if (value == null || value.trim().isEmpty) {
      throw SpeechAuthenticationException(
        '$key is not set. Add it to your .env file.',
      );
    }
    return value.trim();
  }

  /// Returns an authenticated HTTP client, initialising it on first call.
  Future<gauth.AutoRefreshingAuthClient> _client() async {
    if (_authClient != null) return _authClient!;

    final email = _readEnv('GOOGLE_SERVICE_ACCOUNT_EMAIL');
    // The private key is stored in .env with literal \n sequences.
    final rawKey = _readEnv('GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY');
    final privateKey = rawKey.replaceAll('\\n', '\n');

    final credentials = gauth.ServiceAccountCredentials(
      email,
      gauth.ClientId('', null),
      privateKey,
    );

    debugPrint('[GCP] Obtaining OAuth2 access token...');
    _authClient = await gauth.clientViaServiceAccount(credentials, _scopes);
    debugPrint('[GCP] Access token obtained.');
    return _authClient!;
  }

  // ---------------------------------------------------------------------------
  // Speech-to-Text V2
  // ---------------------------------------------------------------------------

  /// Sends [base64Audio] to Cloud Speech-to-Text V2 (chirp_2 model)
  /// and returns a [TranscriptionResult].
  Future<TranscriptionResult> recognize(
    String base64Audio,
    String localeId,
  ) async {
    final uri = Uri.parse(
      'https://${SpeechConfig.sttLocation}-speech.googleapis.com'
      '/v2/projects/$_projectId'
      '/locations/${SpeechConfig.sttLocation}/recognizers/_:recognize',
    );

    final config = {
      'autoDecodingConfig': {},
      'languageCodes': [localeId],
      'model': SpeechConfig.sttModel,
    };

    if (kDebugMode) {
      debugPrint('[GCP] STT config: ${jsonEncode(config)}');
    }

    final body = jsonEncode({'config': config, 'content': base64Audio});

    final json = await _post(uri, body);
    return _parseSttResponse(json);
  }

  TranscriptionResult _parseSttResponse(Map<String, dynamic> json) {
    final results = json['results'] as List<dynamic>?;
    if (results == null || results.isEmpty) {
      return const TranscriptionResult(transcript: '');
    }

    final first = results.first as Map<String, dynamic>;
    final alternatives = first['alternatives'] as List<dynamic>?;
    if (alternatives == null || alternatives.isEmpty) {
      return const TranscriptionResult(transcript: '');
    }

    final alt = alternatives.first as Map<String, dynamic>;
    return TranscriptionResult(
      transcript: alt['transcript'] as String? ?? '',
      confidence: (alt['confidence'] as num?)?.toDouble(),
      detectedLanguage: first['languageCode'] as String?,
    );
  }

  // ---------------------------------------------------------------------------
  // Text-to-Speech V1
  // ---------------------------------------------------------------------------

  /// Synthesises [text] for [localeId] and returns raw MP3 bytes.
  Future<Uint8List> synthesize(String text, String localeId) async {
    final voiceName =
        SpeechConfig.voiceMap[localeId] ?? SpeechConfig.voiceMap['en-US']!;
    final langCode = localeId.length >= 5 ? localeId.substring(0, 5) : localeId;

    final uri = Uri.parse(
      'https://texttospeech.googleapis.com/v1/text:synthesize',
    );

    final body = jsonEncode({
      'input': {'text': text},
      'voice': {'languageCode': langCode, 'name': voiceName},
      'audioConfig': {
        'audioEncoding': SpeechConfig.ttsAudioEncoding,
        'sampleRateHertz': SpeechConfig.ttsSampleRate,
      },
    });

    final json = await _post(uri, body);
    final audioContent = json['audioContent'] as String?;
    if (audioContent == null || audioContent.isEmpty) {
      throw const SpeechUnknownException('TTS response contained no audio.');
    }
    return base64Decode(audioContent);
  }

  // ---------------------------------------------------------------------------
  // Shared HTTP helper
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _post(Uri uri, String body) async {
    try {
      final client = await _client();
      final response = await client
          .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(Duration(seconds: SpeechConfig.httpTimeoutSeconds));

      if (kDebugMode) {
        debugPrint('[GCP] ${uri.path} → ${response.statusCode}');
        if (response.statusCode != 200) {
          debugPrint('[GCP] Error body: ${response.body}');
        }
      }

      return _handleResponse(response);
    } on TimeoutException {
      throw const SpeechTimeoutException();
    } on SpeechException {
      rethrow;
    } catch (e) {
      throw SpeechNetworkException(e.toString());
    }
  }

  Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    String gcpMessage = '';
    try {
      final err = jsonDecode(response.body) as Map<String, dynamic>;
      gcpMessage = ((err['error'] as Map?))?['message'] as String? ?? '';
    } catch (_) {}

    switch (response.statusCode) {
      case 401:
      case 403:
        throw SpeechAuthenticationException(
          gcpMessage.isNotEmpty ? gcpMessage : 'Authentication failed.',
        );
      case 429:
        throw const SpeechQuotaExceededException();
      case 400:
        if (gcpMessage.toLowerCase().contains('language')) {
          throw SpeechUnsupportedLanguageException(gcpMessage);
        }
        throw SpeechUnknownException('Bad request: $gcpMessage');
      default:
        throw SpeechUnknownException(
          'HTTP ${response.statusCode}'
          '${gcpMessage.isNotEmpty ? ': $gcpMessage' : ''}',
        );
    }
  }

  void dispose() => _authClient?.close();
}
