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

// Dart Function Signature
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

class AudioEngineFFI {
  static final AudioEngineFFI _instance = AudioEngineFFI._internal();
  factory AudioEngineFFI() => _instance;

  late final DynamicLibrary _lib;
  late final _ProcessAudioFileDart _processAudioFile;

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
}
