import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'exceptions.dart';
import 'google_speech_client.dart';
import 'speech_models.dart';

/// Online Speech-to-Text service backed by Google Cloud STT V2.
///
/// Records audio to a temporary WAV file, then sends the encoded bytes
/// to the Cloud Speech API when [stopAndTranscribe] is called.
class GcpSttService {
  final GoogleSpeechClient _client;
  final AudioRecorder _recorder = AudioRecorder();

  String _localeId = 'en-US';
  String? _recordingPath;
  bool _isRecording = false;

  GcpSttService(this._client);

  bool get isRecording => _isRecording;

  /// Change the recognition language.
  void setLanguage(String localeId) => _localeId = localeId;

  /// Starts recording microphone audio to a temp WAV file.
  ///
  /// Throws [SpeechPermissionDeniedException] if the mic is not available.
  Future<void> startRecording() async {
    if (_isRecording) return;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) throw const SpeechPermissionDeniedException();

    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/gcp_stt_${DateTime.now().millisecondsSinceEpoch}.wav';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _recordingPath!,
    );

    _isRecording = true;
    debugPrint('[GcpSTT] Recording started → $_recordingPath');
  }

  /// Stops recording and sends the audio to GCP for transcription.
  ///
  /// Returns a [TranscriptionResult] with the recognised text.
  Future<TranscriptionResult> stopAndTranscribe() async {
    if (!_isRecording) {
      throw const SpeechUnknownException('Not currently recording.');
    }

    final stoppedPath = await _recorder.stop();
    _isRecording = false;
    debugPrint('[GcpSTT] Recording stopped. path=$stoppedPath');

    final path = stoppedPath ?? _recordingPath;
    if (path == null) {
      throw const SpeechUnknownException('Recording produced no file.');
    }

    final file = File(path);
    if (!await file.exists()) {
      throw const SpeechUnknownException('Audio file missing after recording.');
    }

    final bytes = await file.readAsBytes();
    debugPrint('[GcpSTT] Audio file size: ${bytes.length} bytes');

    // Clean up temp file.
    await file.delete();
    _recordingPath = null;

    if (bytes.isEmpty) {
      throw const SpeechUnknownException('Recorded audio is empty.');
    }

    final base64Audio = base64Encode(bytes);
    debugPrint('[GcpSTT] Sending to GCP STT (locale: $_localeId)...');
    return _client.recognize(base64Audio, _localeId);
  }

  /// Cancels an in-progress recording without transcribing.
  Future<void> cancel() async {
    if (!_isRecording) return;
    await _recorder.stop();
    _isRecording = false;

    if (_recordingPath != null) {
      final f = File(_recordingPath!);
      if (await f.exists()) await f.delete();
      _recordingPath = null;
    }
    debugPrint('[GcpSTT] Recording cancelled.');
  }

  void dispose() {
    _recorder.dispose();
  }
}
