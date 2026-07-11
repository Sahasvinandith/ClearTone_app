import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// C Function Signature
// int process_audio_file_ffi(
//     const char* inPath,
//     const char* outPath,
//     const float* loss6,
//     float ratio,
//     float attackMs,
//     float releaseMs,
//     const float* thrDb,
//     float masterDb,
//     float wet,
//     float dry
// )
typedef _ProcessAudioFileC =
    Int32 Function(
      Pointer<Utf8> inPath,
      Pointer<Utf8> outPath,
      Pointer<Float> loss6,
      Float ratio,
      Float attackMs,
      Float releaseMs,
      Pointer<Float> thrDb,
      Float masterDb,
      Float wet,
      Float dry,
    );

typedef _ProcessAudioFileDart =
    int Function(
      Pointer<Utf8> inPath,
      Pointer<Utf8> outPath,
      Pointer<Float> loss6,
      double ratio,
      double attackMs,
      double releaseMs,
      Pointer<Float> thrDb,
      double masterDb,
      double wet,
      double dry,
    );

typedef _StartRtStreamC = Int32 Function(Int32 inputDeviceId);
typedef _StartRtStreamDart = int Function(int inputDeviceId);

typedef _StopRtStreamC = Int32 Function();
typedef _StopRtStreamDart = int Function();

typedef _UpdateRtParamsC = Int32 Function(Pointer<Float> loss6);
typedef _UpdateRtParamsDart = int Function(Pointer<Float> loss6);

typedef _GetRtInputSampleRateC = Int32 Function();
typedef _GetRtInputSampleRateDart = int Function();

typedef _DrainRtInputFramesC =
    Int32 Function(Pointer<Float> out, Int32 maxFrames);
typedef _DrainRtInputFramesDart =
    int Function(Pointer<Float> out, int maxFrames);

typedef _ClearRtInputFramesC = Void Function();
typedef _ClearRtInputFramesDart = void Function();

typedef _StartLatencyProbeC = Void Function(Float threshold);
typedef _StartLatencyProbeDart = void Function(double threshold);

typedef _StopLatencyProbeC = Void Function();
typedef _StopLatencyProbeDart = void Function();

typedef _GetLatencyProbeMsC = Double Function();
typedef _GetLatencyProbeMsDart = double Function();

typedef _GetLatencyProbeStatusC = Int32 Function();
typedef _GetLatencyProbeStatusDart = int Function();

typedef _StartChirpLatencyProbeC = Void Function(Int32 captureMs);
typedef _StartChirpLatencyProbeDart = void Function(int captureMs);

typedef _StopChirpLatencyProbeC = Int32 Function();
typedef _StopChirpLatencyProbeDart = int Function();

typedef _GetChirpLatencyMsC = Double Function();
typedef _GetChirpLatencyMsDart = double Function();

typedef _GetChirpLatencyStatusC = Int32 Function();
typedef _GetChirpLatencyStatusDart = int Function();

typedef _GetChirpScoreC = Float Function();
typedef _GetChirpScoreDart = double Function();

typedef _ComputeAcousticChirpLatencyC = Int32 Function(Int64 playbackStartNs);
typedef _ComputeAcousticChirpLatencyDart = int Function(int playbackStartNs);

typedef _DebugStartCaptureC = Void Function();
typedef _DebugStartCaptureDart = void Function();

typedef _DebugStopCaptureC = Void Function();
typedef _DebugStopCaptureDart = void Function();

typedef _DebugSaveCaptureC =
    Int32 Function(Pointer<Utf8> filePath, Int32 source);
typedef _DebugSaveCaptureDart =
    int Function(Pointer<Utf8> filePath, int source);

typedef _DebugGetCaptureSizeC = Int32 Function();
typedef _DebugGetCaptureSizeDart = int Function();

typedef _SetAudioUsageC = Void Function(Int32 usage);
typedef _SetAudioUsageDart = void Function(int usage);

typedef _IsPlayingC = Uint8 Function();
typedef _IsPlayingDart = int Function();

typedef _SetEnvironmentModeC = Int32 Function(Int32 mode);
typedef _SetEnvironmentModeDart = int Function(int mode);

typedef _SetExpanderEnabledC = Int32 Function(Int32 enabled);
typedef _SetExpanderEnabledDart = int Function(int enabled);

// ---- Evidence / diagnostic capture (docs/validation.md) -------------------

typedef _EvidenceStartC =
    Int32 Function(
      Pointer<Utf8> sessionId,
      Int32 experimentType,
      Int32 mode,
      Int32 durationSeconds,
      Int32 captureRawProcessed,
      Int32 captureBandLog,
      Int32 captureLimiterLog,
      Int32 captureFrameLog,
    );
typedef _EvidenceStartDart =
    int Function(
      Pointer<Utf8> sessionId,
      int experimentType,
      int mode,
      int durationSeconds,
      int captureRawProcessed,
      int captureBandLog,
      int captureLimiterLog,
      int captureFrameLog,
    );

typedef _EvidenceStopC = Int32 Function();
typedef _EvidenceStopDart = int Function();

typedef _EvidenceFlushC =
    Int32 Function(Pointer<Utf8> logsDir, Pointer<Utf8> audioDir);
typedef _EvidenceFlushDart =
    int Function(Pointer<Utf8> logsDir, Pointer<Utf8> audioDir);

typedef _EvidenceLogGainUpdateC =
    Void Function(Pointer<Utf8> source, Pointer<Float> gainsDb6);
typedef _EvidenceLogGainUpdateDart =
    void Function(Pointer<Utf8> source, Pointer<Float> gainsDb6);

typedef _GetBandGainsDbC = Void Function(Pointer<Float> outGainsDb6);
typedef _GetBandGainsDbDart = void Function(Pointer<Float> outGainsDb6);

typedef _GetDspParamsC =
    Void Function(
      Pointer<Float> outThrDb6,
      Pointer<Float> outRatio,
      Pointer<Float> outAttackMs,
      Pointer<Float> outReleaseMs,
      Pointer<Float> outLimiterThr,
      Pointer<Float> outWet,
      Pointer<Float> outDry,
    );
typedef _GetDspParamsDart =
    void Function(
      Pointer<Float> outThrDb6,
      Pointer<Float> outRatio,
      Pointer<Float> outAttackMs,
      Pointer<Float> outReleaseMs,
      Pointer<Float> outLimiterThr,
      Pointer<Float> outWet,
      Pointer<Float> outDry,
    );

typedef _GetDspConfigForProfileC =
    Void Function(
      Pointer<Float> loss6,
      Int32 mode,
      Int32 sampleRate,
      Pointer<Float> outGainsDb6,
      Pointer<Float> outThrDb6,
      Pointer<Float> outRatio,
      Pointer<Float> outAttackMs,
      Pointer<Float> outReleaseMs,
      Pointer<Float> outLimiterThr,
      Pointer<Float> outWet,
      Pointer<Float> outDry,
    );
typedef _GetDspConfigForProfileDart =
    void Function(
      Pointer<Float> loss6,
      int mode,
      int sampleRate,
      Pointer<Float> outGainsDb6,
      Pointer<Float> outThrDb6,
      Pointer<Float> outRatio,
      Pointer<Float> outAttackMs,
      Pointer<Float> outReleaseMs,
      Pointer<Float> outLimiterThr,
      Pointer<Float> outWet,
      Pointer<Float> outDry,
    );

typedef _ProcessAudioFileFullC =
    Int32 Function(
      Pointer<Utf8> inPath,
      Pointer<Utf8> outPath,
      Pointer<Float> loss6,
      Int32 mode,
      Pointer<Utf8> bandLogCsvPath,
      Pointer<Utf8> limiterLogCsvPath,
      Pointer<Utf8> sourceLabel,
    );
typedef _ProcessAudioFileFullDart =
    int Function(
      Pointer<Utf8> inPath,
      Pointer<Utf8> outPath,
      Pointer<Float> loss6,
      int mode,
      Pointer<Utf8> bandLogCsvPath,
      Pointer<Utf8> limiterLogCsvPath,
      Pointer<Utf8> sourceLabel,
    );

typedef _GenerateToneWavC =
    Int32 Function(
      Pointer<Utf8> path,
      Float freqHz,
      Float durationSec,
      Int32 sampleRate,
      Float amplitudeDbFs,
    );
typedef _GenerateToneWavDart =
    int Function(
      Pointer<Utf8> path,
      double freqHz,
      double durationSec,
      int sampleRate,
      double amplitudeDbFs,
    );

typedef _GenerateSweepWavC =
    Int32 Function(
      Pointer<Utf8> path,
      Float f0Hz,
      Float f1Hz,
      Float durationSec,
      Int32 sampleRate,
      Float amplitudeDbFs,
    );
typedef _GenerateSweepWavDart =
    int Function(
      Pointer<Utf8> path,
      double f0Hz,
      double f1Hz,
      double durationSec,
      int sampleRate,
      double amplitudeDbFs,
    );

typedef _GenerateSyntheticTestWavC =
    Int32 Function(
      Pointer<Utf8> path,
      Float durationSec,
      Int32 sampleRate,
    );
typedef _GenerateSyntheticTestWavDart =
    int Function(Pointer<Utf8> path, double durationSec, int sampleRate);

class AudioEngineFFI {
  static final AudioEngineFFI _instance = AudioEngineFFI._internal();
  factory AudioEngineFFI() => _instance;

  late final DynamicLibrary _lib;
  late final _ProcessAudioFileDart _processAudioFile;
  late final _StartRtStreamDart _startRtStream;
  late final _StopRtStreamDart _stopRtStream;
  late final _UpdateRtParamsDart _updateRtParams;
  late final _GetRtInputSampleRateDart _getRtInputSampleRate;
  late final _DrainRtInputFramesDart _drainRtInputFrames;
  late final _ClearRtInputFramesDart _clearRtInputFrames;
  late final _StartLatencyProbeDart _startLatencyProbe;
  late final _StopLatencyProbeDart _stopLatencyProbe;
  late final _GetLatencyProbeMsDart _getLatencyProbeMs;
  late final _GetLatencyProbeStatusDart _getLatencyProbeStatus;
  late final _StartChirpLatencyProbeDart _startChirpLatencyProbe;
  late final _StopChirpLatencyProbeDart _stopChirpLatencyProbe;
  late final _GetChirpLatencyMsDart _getChirpLatencyMs;
  late final _GetChirpLatencyStatusDart _getChirpLatencyStatus;
  late final _GetChirpScoreDart _getChirpInputScore;
  late final _GetChirpScoreDart _getChirpOutputScore;
  late final _ComputeAcousticChirpLatencyDart _computeAcousticChirpLatency;
  late final _GetChirpLatencyMsDart _getAcousticChirpLatencyMs;
  late final _GetChirpScoreDart _getAcousticChirpScore;
  late final _DebugStartCaptureDart _debugStartCapture;
  late final _DebugStopCaptureDart _debugStopCapture;
  late final _DebugSaveCaptureDart _debugSaveCapture;
  late final _DebugGetCaptureSizeDart _debugGetCaptureSize;
  late final _SetAudioUsageDart _setAudioUsage;
  late final _IsPlayingDart _isPlaying;
  late final _SetEnvironmentModeDart _setEnvironmentMode;
  late final _SetExpanderEnabledDart _setExpanderEnabled;
  late final _EvidenceStartDart _evidenceStart;
  late final _EvidenceStopDart _evidenceStop;
  late final _EvidenceFlushDart _evidenceFlush;
  late final _EvidenceLogGainUpdateDart _evidenceLogGainUpdate;
  late final _GetBandGainsDbDart _getBandGainsDb;
  late final _GetDspParamsDart _getDspParams;
  late final _GetDspConfigForProfileDart _getDspConfigForProfile;
  late final _ProcessAudioFileFullDart _processAudioFileFull;
  late final _GenerateToneWavDart _generateToneWav;
  late final _GenerateSweepWavDart _generateSweepWav;
  late final _GenerateSyntheticTestWavDart _generateSyntheticTestWav;

  // Persistent native buffer for updateRtParams — avoids calloc/free on every
  // slider change (which fires many times per second during a drag).
  final Pointer<Float> _rtLossBuffer = calloc<Float>(6);
  static const int _inputDrainBufferFrames = 8192;
  final Pointer<Float> _inputDrainBuffer = calloc<Float>(
    _inputDrainBufferFrames,
  );

  AudioEngineFFI._internal() {
    if (Platform.isAndroid) {
      _lib = DynamicLibrary.open('libcleartone_audio_engine.so');
    } else {
      throw UnsupportedError(
        'AudioEngineFFI is currently only supported on Android.',
      );
    }

    _processAudioFile = _lib
        .lookupFunction<_ProcessAudioFileC, _ProcessAudioFileDart>(
          'process_audio_file_ffi',
        );

    _startRtStream = _lib.lookupFunction<_StartRtStreamC, _StartRtStreamDart>(
      'start_rt_stream_ffi',
    );

    _stopRtStream = _lib.lookupFunction<_StopRtStreamC, _StopRtStreamDart>(
      'stop_rt_stream_ffi',
    );

    _updateRtParams = _lib
        .lookupFunction<_UpdateRtParamsC, _UpdateRtParamsDart>(
          'update_rt_params_ffi',
        );

    _getRtInputSampleRate = _lib
        .lookupFunction<_GetRtInputSampleRateC, _GetRtInputSampleRateDart>(
          'get_rt_input_sample_rate_ffi',
        );

    _drainRtInputFrames = _lib
        .lookupFunction<_DrainRtInputFramesC, _DrainRtInputFramesDart>(
          'drain_rt_input_frames_ffi',
        );

    _clearRtInputFrames = _lib
        .lookupFunction<_ClearRtInputFramesC, _ClearRtInputFramesDart>(
          'clear_rt_input_frames_ffi',
        );

    _startLatencyProbe = _lib
        .lookupFunction<_StartLatencyProbeC, _StartLatencyProbeDart>(
          'start_latency_probe_ffi',
        );

    _stopLatencyProbe = _lib
        .lookupFunction<_StopLatencyProbeC, _StopLatencyProbeDart>(
          'stop_latency_probe_ffi',
        );

    _getLatencyProbeMs = _lib
        .lookupFunction<_GetLatencyProbeMsC, _GetLatencyProbeMsDart>(
          'get_latency_probe_ms_ffi',
        );

    _getLatencyProbeStatus = _lib
        .lookupFunction<_GetLatencyProbeStatusC, _GetLatencyProbeStatusDart>(
          'get_latency_probe_status_ffi',
        );

    _startChirpLatencyProbe = _lib
        .lookupFunction<_StartChirpLatencyProbeC, _StartChirpLatencyProbeDart>(
          'start_chirp_latency_probe_ffi',
        );

    _stopChirpLatencyProbe = _lib
        .lookupFunction<_StopChirpLatencyProbeC, _StopChirpLatencyProbeDart>(
          'stop_chirp_latency_probe_ffi',
        );

    _getChirpLatencyMs = _lib
        .lookupFunction<_GetChirpLatencyMsC, _GetChirpLatencyMsDart>(
          'get_chirp_latency_ms_ffi',
        );

    _getChirpLatencyStatus = _lib
        .lookupFunction<_GetChirpLatencyStatusC, _GetChirpLatencyStatusDart>(
          'get_chirp_latency_status_ffi',
        );

    _getChirpInputScore = _lib
        .lookupFunction<_GetChirpScoreC, _GetChirpScoreDart>(
          'get_chirp_input_score_ffi',
        );

    _getChirpOutputScore = _lib
        .lookupFunction<_GetChirpScoreC, _GetChirpScoreDart>(
          'get_chirp_output_score_ffi',
        );

    _computeAcousticChirpLatency = _lib
        .lookupFunction<
          _ComputeAcousticChirpLatencyC,
          _ComputeAcousticChirpLatencyDart
        >('compute_acoustic_chirp_latency_ffi');

    _getAcousticChirpLatencyMs = _lib
        .lookupFunction<_GetChirpLatencyMsC, _GetChirpLatencyMsDart>(
          'get_acoustic_chirp_latency_ms_ffi',
        );

    _getAcousticChirpScore = _lib
        .lookupFunction<_GetChirpScoreC, _GetChirpScoreDart>(
          'get_acoustic_chirp_score_ffi',
        );

    _debugStartCapture = _lib
        .lookupFunction<_DebugStartCaptureC, _DebugStartCaptureDart>(
          'debug_start_capture_ffi',
        );

    _debugStopCapture = _lib
        .lookupFunction<_DebugStopCaptureC, _DebugStopCaptureDart>(
          'debug_stop_capture_ffi',
        );

    _debugSaveCapture = _lib
        .lookupFunction<_DebugSaveCaptureC, _DebugSaveCaptureDart>(
          'debug_save_capture_ffi',
        );

    _debugGetCaptureSize = _lib
        .lookupFunction<_DebugGetCaptureSizeC, _DebugGetCaptureSizeDart>(
          'debug_get_capture_size_ffi',
        );

    _setAudioUsage = _lib.lookupFunction<_SetAudioUsageC, _SetAudioUsageDart>(
      'set_audio_usage_ffi',
    );

    _isPlaying = _lib.lookupFunction<_IsPlayingC, _IsPlayingDart>(
      'is_playing_ffi',
    );

    _setEnvironmentMode = _lib
        .lookupFunction<_SetEnvironmentModeC, _SetEnvironmentModeDart>(
          'set_environment_mode_ffi',
        );

    _setExpanderEnabled = _lib
        .lookupFunction<_SetExpanderEnabledC, _SetExpanderEnabledDart>(
          'set_expander_enabled_ffi',
        );

    _evidenceStart = _lib.lookupFunction<_EvidenceStartC, _EvidenceStartDart>(
      'evidence_start_ffi',
    );

    _evidenceStop = _lib.lookupFunction<_EvidenceStopC, _EvidenceStopDart>(
      'evidence_stop_ffi',
    );

    _evidenceFlush = _lib.lookupFunction<_EvidenceFlushC, _EvidenceFlushDart>(
      'evidence_flush_ffi',
    );

    _evidenceLogGainUpdate = _lib
        .lookupFunction<_EvidenceLogGainUpdateC, _EvidenceLogGainUpdateDart>(
          'evidence_log_gain_update_ffi',
        );

    _getBandGainsDb = _lib
        .lookupFunction<_GetBandGainsDbC, _GetBandGainsDbDart>(
          'get_band_gains_db_ffi',
        );

    _getDspParams = _lib.lookupFunction<_GetDspParamsC, _GetDspParamsDart>(
      'get_dsp_params_ffi',
    );

    _getDspConfigForProfile = _lib
        .lookupFunction<_GetDspConfigForProfileC, _GetDspConfigForProfileDart>(
          'get_dsp_config_for_profile_ffi',
        );

    _processAudioFileFull = _lib
        .lookupFunction<_ProcessAudioFileFullC, _ProcessAudioFileFullDart>(
          'process_audio_file_full_ffi',
        );

    _generateToneWav = _lib
        .lookupFunction<_GenerateToneWavC, _GenerateToneWavDart>(
          'generate_tone_wav_ffi',
        );

    _generateSweepWav = _lib
        .lookupFunction<_GenerateSweepWavC, _GenerateSweepWavDart>(
          'generate_sweep_wav_ffi',
        );

    _generateSyntheticTestWav = _lib
        .lookupFunction<
          _GenerateSyntheticTestWavC,
          _GenerateSyntheticTestWavDart
        >('generate_synthetic_test_wav_ffi');
  }

  /// Processes the audio file at [inPath] and saves it to [outPath].
  /// Returns 0 on success, or an error code > 0 on failure.
  int processAudio({
    required String inPath,
    required String outPath,
    required List<double> loss6,
    double ratio = 4.0,
    double attackMs = 20.0,
    double releaseMs = 250.0,
    List<double> thrDb = const [-18.0, -22.0, -26.0, -30.0, -34.0, -36.0],
    double masterDb = 0.0,
    double wet = 1.0,
    double dry = 1.0,
  }) {
    if (loss6.length != 6) {
      throw ArgumentError('loss6 must contain exactly 6 elements');
    }
    if (thrDb.length != 6) {
      throw ArgumentError('thrDb must contain exactly 6 elements');
    }

    final Pointer<Utf8> inPathPtr = inPath.toNativeUtf8();
    final Pointer<Utf8> outPathPtr = outPath.toNativeUtf8();

    final Pointer<Float> loss6Ptr = calloc<Float>(6);
    for (int i = 0; i < 6; i++) {
      loss6Ptr[i] = loss6[i];
    }

    final Pointer<Float> thrDbPtr = calloc<Float>(6);
    for (int i = 0; i < 6; i++) {
      thrDbPtr[i] = thrDb[i];
    }

    try {
      final int result = _processAudioFile(
        inPathPtr,
        outPathPtr,
        loss6Ptr,
        ratio,
        attackMs,
        releaseMs,
        thrDbPtr,
        masterDb,
        wet,
        dry,
      );
      return result;
    } finally {
      // Free allocated memory
      calloc.free(inPathPtr);
      calloc.free(outPathPtr);
      calloc.free(loss6Ptr);
      calloc.free(thrDbPtr);
    }
  }

  /// Starts the Oboe real-time audio stream.
  int startRtStream(int inputDeviceId) {
    return _startRtStream(inputDeviceId);
  }

  /// Stops the Oboe real-time audio stream.
  int stopRtStream() {
    return _stopRtStream();
  }

  /// Updates the hearing loss profile for the active real-time stream.
  int updateRtParams(List<double> loss6) {
    if (loss6.length != 6) {
      throw ArgumentError('loss6 must contain exactly 6 elements');
    }
    for (int i = 0; i < 6; i++) {
      _rtLossBuffer[i] = loss6[i];
    }
    return _updateRtParams(_rtLossBuffer);
  }

  /// Returns the active Oboe input sample rate, or 0 when the stream is stopped.
  int getRtInputSampleRate() {
    return _getRtInputSampleRate();
  }

  /// Drains raw pre-DSP mic samples from the active Oboe stream into [target].
  /// Returns the number of frames copied.
  int drainRtInputFrames(Float32List target) {
    final int maxFrames = target.length < _inputDrainBufferFrames
        ? target.length
        : _inputDrainBufferFrames;
    if (maxFrames <= 0) return 0;

    final int frames = _drainRtInputFrames(_inputDrainBuffer, maxFrames);
    if (frames <= 0) return 0;

    target.setRange(0, frames, _inputDrainBuffer.asTypedList(frames));
    return frames;
  }

  /// Drops pending raw mic frames so a new detector starts from live audio.
  void clearRtInputFrames() {
    _clearRtInputFrames();
  }

  /// Arms a one-shot native latency probe. The probe detects the first input
  /// and output samples whose absolute amplitude is at least [threshold].
  void startLatencyProbe(double threshold) {
    _startLatencyProbe(threshold);
  }

  void stopLatencyProbe() {
    _stopLatencyProbe();
  }

  /// Returns measured latency in milliseconds, or -1 until a measurement exists.
  double getLatencyProbeMs() {
    return _getLatencyProbeMs();
  }

  /// 0 = waiting, 1 = measured, -1 = stopped/timed out, -2 = timestamp unavailable.
  int getLatencyProbeStatus() {
    return _getLatencyProbeStatus();
  }

  /// Captures input/output audio for a correlation-based chirp latency test.
  void startChirpLatencyProbe({int captureMs = 1000}) {
    _startChirpLatencyProbe(captureMs);
  }

  /// Stops capture and computes chirp correlation. Returns native status.
  int stopChirpLatencyProbe() {
    return _stopChirpLatencyProbe();
  }

  double getChirpLatencyMs() {
    return _getChirpLatencyMs();
  }

  /// 0 = idle/capturing, 1 = measured, -1 = no confident match, -2 = timestamp unavailable.
  int getChirpLatencyStatus() {
    return _getChirpLatencyStatus();
  }

  double getChirpInputScore() {
    return _getChirpInputScore();
  }

  double getChirpOutputScore() {
    return _getChirpOutputScore();
  }

  /// Computes acoustic output latency using the current chirp capture input
  /// window and the monotonic timestamp returned by Android chirp playback.
  int computeAcousticChirpLatency(int playbackStartNs) {
    return _computeAcousticChirpLatency(playbackStartNs);
  }

  double getAcousticChirpLatencyMs() {
    return _getAcousticChirpLatencyMs();
  }

  double getAcousticChirpScore() {
    return _getAcousticChirpScore();
  }

  /// Starts capturing input audio samples for debugging.
  void debugStartCapture() {
    _debugStartCapture();
  }

  /// Stops capturing input audio samples.
  void debugStopCapture() {
    _debugStopCapture();
  }

  /// Saves a captured buffer to [filePath] as raw float32 PCM.
  /// [source] 0 for input (mic), 1 for output (processed).
  int debugSaveCapture(String filePath, int source) {
    final Pointer<Utf8> pathPtr = filePath.toNativeUtf8();
    try {
      return _debugSaveCapture(pathPtr, source);
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Returns the number of samples currently in the capture buffer.
  int debugGetCaptureSize() {
    return _debugGetCaptureSize();
  }

  /// Configures the Oboe stream usage.
  /// 2 for VoiceCommunication (default), 1 for Media.
  void setAudioUsage(int usage) {
    _setAudioUsage(usage);
  }

  bool isPlaying() {
    return _isPlaying() != 0;
  }

  /// Sets the environment mode (0 = Standard, 1 = Transit, 2 = Conversation).
  int setEnvironmentMode(int mode) {
    return _setEnvironmentMode(mode);
  }

  /// Enables or disables conversation-mode speech/noise suppression.
  /// Use for diagnostics when checking own-voice feedback or voice fading.
  int setExpanderEnabled(bool enabled) {
    return _setExpanderEnabled(enabled ? 1 : 0);
  }

  // ---- Evidence / diagnostic capture (docs/validation.md) -----------------

  /// Starts an evidence/diagnostic capture session.
  /// experimentType: 0 live_microphone_test, 1 pure_tone_test, 2 sweep_test,
  ///                 3 mode_comparison_test, 4 limiter_test.
  /// mode: 0 Standard, 1 Transit, 2 Conversation.
  int evidenceStart({
    required String sessionId,
    required int experimentType,
    required int mode,
    required int durationSeconds,
    bool captureRawProcessed = true,
    bool captureBandLog = true,
    bool captureLimiterLog = true,
    bool captureFrameLog = true,
  }) {
    final Pointer<Utf8> idPtr = sessionId.toNativeUtf8();
    try {
      return _evidenceStart(
        idPtr,
        experimentType,
        mode,
        durationSeconds,
        captureRawProcessed ? 1 : 0,
        captureBandLog ? 1 : 0,
        captureLimiterLog ? 1 : 0,
        captureFrameLog ? 1 : 0,
      );
    } finally {
      calloc.free(idPtr);
    }
  }

  /// Stops new writes into the active evidence session's buffers.
  int evidenceStop() {
    return _evidenceStop();
  }

  /// Flushes captured logs (CSV) into [logsDir] and any captured live-mic
  /// WAVs into [audioDir]. Both directories must already exist. Safe to call
  /// after each experiment step -- band/limiter CSV rows accumulate across
  /// calls within the same session rather than being overwritten.
  int evidenceFlush({required String logsDir, required String audioDir}) {
    final Pointer<Utf8> logsPtr = logsDir.toNativeUtf8();
    final Pointer<Utf8> audioPtr = audioDir.toNativeUtf8();
    try {
      return _evidenceFlush(logsPtr, audioPtr);
    } finally {
      calloc.free(logsPtr);
      calloc.free(audioPtr);
    }
  }

  /// Records a gain-slider/hearing-profile change into gain_update_log.csv.
  /// source: "hearing_profile" / "manual_slider" / "mode_adjustment" / "test_override".
  void evidenceLogGainUpdate(String source, List<double> gainsDb6) {
    if (gainsDb6.length != 6) {
      throw ArgumentError('gainsDb6 must contain exactly 6 elements');
    }
    final Pointer<Utf8> sourcePtr = source.toNativeUtf8();
    final Pointer<Float> gainsPtr = calloc<Float>(6);
    for (int i = 0; i < 6; i++) {
      gainsPtr[i] = gainsDb6[i];
    }
    try {
      _evidenceLogGainUpdate(sourcePtr, gainsPtr);
    } finally {
      calloc.free(sourcePtr);
      calloc.free(gainsPtr);
    }
  }

  /// Current per-band makeup gain in dB, derived from the active hearing
  /// profile / slider values -- for session_config.json / dsp_config.json /
  /// gain_profile.csv.
  List<double> getBandGainsDb() {
    final Pointer<Float> buf = calloc<Float>(6);
    try {
      _getBandGainsDb(buf);
      return List<double>.generate(6, (i) => buf[i]);
    } finally {
      calloc.free(buf);
    }
  }

  /// Current compressor/limiter configuration, for dsp_config.json.
  Map<String, dynamic> getDspParams() {
    final Pointer<Float> thrDb = calloc<Float>(6);
    final Pointer<Float> ratio = calloc<Float>(1);
    final Pointer<Float> attackMs = calloc<Float>(1);
    final Pointer<Float> releaseMs = calloc<Float>(1);
    final Pointer<Float> limiterThr = calloc<Float>(1);
    final Pointer<Float> wet = calloc<Float>(1);
    final Pointer<Float> dry = calloc<Float>(1);
    try {
      _getDspParams(thrDb, ratio, attackMs, releaseMs, limiterThr, wet, dry);
      return {
        'threshold_db_per_band': List<double>.generate(6, (i) => thrDb[i]),
        'ratio': ratio[0],
        'attack_ms': attackMs[0],
        'release_ms': releaseMs[0],
        'limiter_threshold': limiterThr[0],
        'wet_mix': wet[0],
        'dry_mix': dry[0],
      };
    } finally {
      calloc.free(thrDb);
      calloc.free(ratio);
      calloc.free(attackMs);
      calloc.free(releaseMs);
      calloc.free(limiterThr);
      calloc.free(wet);
      calloc.free(dry);
    }
  }

  /// Deterministic dsp_config.json / gain_profile.csv source for a given
  /// [loss6] + [mode], independent of whether the live real-time engine is
  /// running. Builds a fresh RealtimeProcessor natively (the exact same
  /// class -- and the exact same construction -- process_audio_file_full
  /// uses), so this always matches what an offline experiment run with the
  /// same [loss6]/[mode] actually applied. Prefer this over
  /// [getBandGainsDb]/[getDspParams] for evidence-session metadata; those
  /// two read live engine state and are wrong if the engine was never
  /// started or is in a different mode than the experiment used.
  Map<String, dynamic> getDspConfigForProfile({
    required List<double> loss6,
    required int mode,
    int sampleRate = 48000,
  }) {
    if (loss6.length != 6) {
      throw ArgumentError('loss6 must contain exactly 6 elements');
    }
    final Pointer<Float> loss6Ptr = calloc<Float>(6);
    for (int i = 0; i < 6; i++) {
      loss6Ptr[i] = loss6[i];
    }
    final Pointer<Float> gainsDb = calloc<Float>(6);
    final Pointer<Float> thrDb = calloc<Float>(6);
    final Pointer<Float> ratio = calloc<Float>(1);
    final Pointer<Float> attackMs = calloc<Float>(1);
    final Pointer<Float> releaseMs = calloc<Float>(1);
    final Pointer<Float> limiterThr = calloc<Float>(1);
    final Pointer<Float> wet = calloc<Float>(1);
    final Pointer<Float> dry = calloc<Float>(1);
    try {
      _getDspConfigForProfile(
        loss6Ptr,
        mode,
        sampleRate,
        gainsDb,
        thrDb,
        ratio,
        attackMs,
        releaseMs,
        limiterThr,
        wet,
        dry,
      );
      return {
        'gain_db_per_band': List<double>.generate(6, (i) => gainsDb[i]),
        'threshold_db_per_band': List<double>.generate(6, (i) => thrDb[i]),
        'ratio': ratio[0],
        'attack_ms': attackMs[0],
        'release_ms': releaseMs[0],
        'limiter_threshold': limiterThr[0],
        'wet_mix': wet[0],
        'dry_mix': dry[0],
      };
    } finally {
      calloc.free(loss6Ptr);
      calloc.free(gainsDb);
      calloc.free(thrDb);
      calloc.free(ratio);
      calloc.free(attackMs);
      calloc.free(releaseMs);
      calloc.free(limiterThr);
      calloc.free(wet);
      calloc.free(dry);
    }
  }

  /// Offline pure-tone/sweep/mode-comparison verification: runs [inPath]
  /// through a freshly-constructed RealtimeProcessor -- the exact same class
  /// the live Oboe engine uses -- with [loss6] and [mode], writes
  /// [outPath], and optionally appends block-aggregated diagnostics to
  /// [bandLogCsvPath] / [limiterLogCsvPath] (leave null to skip either).
  /// Returns 0 on success. No microphone or Oboe stream is involved.
  int processAudioFileFull({
    required String inPath,
    required String outPath,
    required List<double> loss6,
    required int mode,
    String? bandLogCsvPath,
    String? limiterLogCsvPath,
    String sourceLabel = 'offline',
  }) {
    if (loss6.length != 6) {
      throw ArgumentError('loss6 must contain exactly 6 elements');
    }
    final Pointer<Utf8> inPtr = inPath.toNativeUtf8();
    final Pointer<Utf8> outPtr = outPath.toNativeUtf8();
    final Pointer<Float> loss6Ptr = calloc<Float>(6);
    for (int i = 0; i < 6; i++) {
      loss6Ptr[i] = loss6[i];
    }
    final Pointer<Utf8> bandPtr = bandLogCsvPath != null
        ? bandLogCsvPath.toNativeUtf8()
        : nullptr;
    final Pointer<Utf8> limiterPtr = limiterLogCsvPath != null
        ? limiterLogCsvPath.toNativeUtf8()
        : nullptr;
    final Pointer<Utf8> sourcePtr = sourceLabel.toNativeUtf8();
    try {
      return _processAudioFileFull(
        inPtr,
        outPtr,
        loss6Ptr,
        mode,
        bandPtr,
        limiterPtr,
        sourcePtr,
      );
    } finally {
      calloc.free(inPtr);
      calloc.free(outPtr);
      calloc.free(loss6Ptr);
      if (bandPtr != nullptr) calloc.free(bandPtr);
      if (limiterPtr != nullptr) calloc.free(limiterPtr);
      calloc.free(sourcePtr);
    }
  }

  /// Generates a mono pure-tone WAV for pure-tone DSP verification.
  int generateToneWav({
    required String path,
    required double freqHz,
    required double durationSec,
    required int sampleRate,
    double amplitudeDbFs = -18.0,
  }) {
    final Pointer<Utf8> pathPtr = path.toNativeUtf8();
    try {
      return _generateToneWav(
        pathPtr,
        freqHz,
        durationSec,
        sampleRate,
        amplitudeDbFs,
      );
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Generates a mono logarithmic sine-sweep WAV for frequency-response
  /// verification.
  int generateSweepWav({
    required String path,
    double f0Hz = 20.0,
    double f1Hz = 10000.0,
    double durationSec = 10.0,
    required int sampleRate,
    double amplitudeDbFs = -24.0,
  }) {
    final Pointer<Utf8> pathPtr = path.toNativeUtf8();
    try {
      return _generateSweepWav(
        pathPtr,
        f0Hz,
        f1Hz,
        durationSec,
        sampleRate,
        amplitudeDbFs,
      );
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Generates a synthetic speech+noise WAV for mode-comparison evidence.
  int generateSyntheticTestWav({
    required String path,
    required double durationSec,
    required int sampleRate,
  }) {
    final Pointer<Utf8> pathPtr = path.toNativeUtf8();
    try {
      return _generateSyntheticTestWav(pathPtr, durationSec, sampleRate);
    } finally {
      calloc.free(pathPtr);
    }
  }
}
