import 'dart:ffi';
import 'dart:io';
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

typedef _DebugStartCaptureC = Void Function();
typedef _DebugStartCaptureDart = void Function();

typedef _DebugStopCaptureC = Void Function();
typedef _DebugStopCaptureDart = void Function();

typedef _DebugSaveCaptureC = Int32 Function(Pointer<Utf8> filePath, Int32 source);
typedef _DebugSaveCaptureDart = int Function(Pointer<Utf8> filePath, int source);

typedef _DebugGetCaptureSizeC = Int32 Function();
typedef _DebugGetCaptureSizeDart = int Function();

typedef _SetAudioUsageC = Void Function(Int32 usage);
typedef _SetAudioUsageDart = void Function(int usage);

typedef _IsPlayingC = Uint8 Function();
typedef _IsPlayingDart = int Function();

typedef _GetEngineStateC = Int32 Function();
typedef _GetEngineStateDart = int Function();

class AudioEngineFFI {
  static final AudioEngineFFI _instance = AudioEngineFFI._internal();
  factory AudioEngineFFI() => _instance;

  late final DynamicLibrary _lib;
  late final _ProcessAudioFileDart _processAudioFile;
  late final _StartRtStreamDart _startRtStream;
  late final _StopRtStreamDart _stopRtStream;
  late final _UpdateRtParamsDart _updateRtParams;
  late final _DebugStartCaptureDart _debugStartCapture;
  late final _DebugStopCaptureDart _debugStopCapture;
  late final _DebugSaveCaptureDart _debugSaveCapture;
  late final _DebugGetCaptureSizeDart _debugGetCaptureSize;
  late final _SetAudioUsageDart _setAudioUsage;
  late final _IsPlayingDart _isPlaying;
  late final _GetEngineStateDart _getEngineState;

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

    _debugStartCapture = _lib.lookupFunction<_DebugStartCaptureC,
        _DebugStartCaptureDart>('debug_start_capture_ffi');

    _debugStopCapture = _lib.lookupFunction<_DebugStopCaptureC,
        _DebugStopCaptureDart>('debug_stop_capture_ffi');

    _debugSaveCapture = _lib.lookupFunction<_DebugSaveCaptureC,
        _DebugSaveCaptureDart>('debug_save_capture_ffi');

    _debugGetCaptureSize = _lib.lookupFunction<_DebugGetCaptureSizeC,
        _DebugGetCaptureSizeDart>('debug_get_capture_size_ffi');

    _setAudioUsage = _lib.lookupFunction<_SetAudioUsageC, _SetAudioUsageDart>(
      'set_audio_usage_ffi',
    );

    _isPlaying = _lib.lookupFunction<_IsPlayingC, _IsPlayingDart>(
      'is_playing_ffi',
    );

    _getEngineState = _lib.lookupFunction<_GetEngineStateC, _GetEngineStateDart>(
      'get_engine_state_ffi',
    );
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
    print("Update Rt Params: $loss6");
    if (loss6.length != 6) {
      throw ArgumentError('loss6 must contain exactly 6 elements');
    }

    final Pointer<Float> loss6Ptr = calloc<Float>(6);
    for (int i = 0; i < 6; i++) {
      loss6Ptr[i] = loss6[i];
    }

    try {
      return _updateRtParams(loss6Ptr);
    } finally {
      calloc.free(loss6Ptr);
    }
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

  /// Returns the engine state: 0=STOPPED, 1=RUNNING, 2=ERROR_NEEDS_RESTART.
  int getEngineState() {
    return _getEngineState();
  }
}
