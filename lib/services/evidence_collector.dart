import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../audio_engine_ffi.dart';

/// Experiment types selectable from the Evidence screen (docs/validation.md).
enum EvidenceExperimentType {
  liveMicrophoneTest(0, 'Live microphone test'),
  pureToneTest(1, 'Pure-tone test'),
  sweepTest(2, 'Frequency-sweep test'),
  modeComparisonTest(3, 'Mode comparison test'),
  limiterTest(4, 'Limiter / clipping test');

  final int code;
  final String label;
  const EvidenceExperimentType(this.code, this.label);
}

const List<double> kPureToneFrequenciesHz = [250, 500, 1000, 2000, 4000, 8000];
const int kEvidenceSampleRate = 48000;

/// Orchestrates DSP evidence collection: creates a timestamped session
/// folder, writes metadata, runs the offline pure-tone/sweep/mode-comparison
/// experiments through the real DSP pipeline (via AudioEngineFFI), and
/// drives live-microphone capture start/stop/flush. Pure Dart/IO glue --
/// none of this runs on the audio thread; all real-time-safety guarantees
/// live in the native evidence.h / audio_engine.cpp.
class EvidenceCollector {
  static const MethodChannel _platform = MethodChannel('com.cleartone/audio');

  final AudioEngineFFI _engine = AudioEngineFFI();

  /// Creates cleartone_evidence/session_YYYYMMDD_HHMMSS/{metadata,audio,
  /// logs,plots,summary} under app-specific external storage and returns
  /// the session's `_SessionPaths`.
  Future<SessionPaths> createSession() async {
    final Directory? extDir = await getExternalStorageDirectory();
    final Directory baseDir = Directory(
      '${(extDir ?? await getApplicationDocumentsDirectory()).path}/cleartone_evidence',
    );
    final String sessionId = _sessionIdNow();
    final Directory sessionDir = Directory('${baseDir.path}/$sessionId');

    final paths = SessionPaths(sessionId: sessionId, root: sessionDir.path);
    for (final dir in [
      paths.root,
      paths.metadata,
      paths.audio,
      paths.logs,
      paths.plots,
      paths.summary,
    ]) {
      await Directory(dir).create(recursive: true);
    }
    return paths;
  }

  String _sessionIdNow() {
    final now = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return 'session_${now.year}${p2(now.month)}${p2(now.day)}_'
        '${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
  }

  /// Writes metadata/session_config.json, metadata/device_info.json,
  /// metadata/dsp_config.json, metadata/gain_profile.csv.
  Future<void> writeMetadata(
    SessionPaths paths, {
    required EvidenceExperimentType experimentType,
    required int mode,
    required List<double> loss6,
    required String modeLabel,
    Map<String, dynamic>? selectedAudioDevice,
    String audioRoute = 'unknown',
    String testNotes = '',
  }) async {
    Map<String, dynamic> deviceInfo;
    try {
      final result = await _platform.invokeMapMethod<String, dynamic>(
        'getDeviceInfo',
      );
      deviceInfo = result ?? {};
    } catch (e) {
      deviceInfo = {'error': 'getDeviceInfo failed: $e'};
    }

    // Computed deterministically from (loss6, mode) via a fresh native
    // RealtimeProcessor -- NOT from the live engine's global state, which
    // may never have been started or may be in a different mode than the
    // one these experiments actually ran with (see getDspConfigForProfile).
    final dspParams = _engine.getDspConfigForProfile(
      loss6: loss6,
      mode: mode,
      sampleRate: kEvidenceSampleRate,
    );
    final List<double> gainsDb = List<double>.from(
      dspParams['gain_db_per_band'] as List,
    );
    final int sampleRate = _engine.isPlaying()
        ? (_engine.getRtInputSampleRate() > 0
              ? _engine.getRtInputSampleRate()
              : kEvidenceSampleRate)
        : kEvidenceSampleRate;

    final sessionConfig = {
      'session_id': paths.sessionId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'experiment_type': experimentType.name,
      'app_version': deviceInfo['app_version'] ?? 'unknown',
      'phone_model': deviceInfo['phone_model'] ?? 'unknown',
      'android_version': deviceInfo['android_version'] ?? 'unknown',
      'headphone_or_earbud_model': selectedAudioDevice?['name'] ?? 'unknown',
      'audio_route': audioRoute,
      'sample_rate': sampleRate,
      'frames_per_callback': null,
      'buffer_size_in_frames': null,
      'performance_mode_requested': 'low_latency',
      'sharing_mode_requested': 'exclusive',
      'actual_input_sample_rate': sampleRate,
      'actual_output_sample_rate': sampleRate,
      'active_mode': modeLabel,
      'microphone_preset': 'VoicePerformance',
      'test_notes': testNotes,
    };
    await File(
      '${paths.metadata}/session_config.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(sessionConfig));
    await File(
      '${paths.metadata}/device_info.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(deviceInfo));

    final dspConfig = {
      'crossover_edges_hz': [500, 1000, 2000, 4000, 8000],
      'bands': ['<500', '500-1000', '1000-2000', '2000-4000', '4000-8000', '>8000'],
      'filter_type':
          'fourth-order Linkwitz-Riley-style using cascaded Butterworth biquads',
      'gain_db_per_band': gainsDb,
      'gain_linear_per_band': gainsDb.map((db) => _dbToLinear(db)).toList(),
      'compression_ratio_per_band': List.filled(6, dspParams['ratio']),
      'threshold_db_per_band': dspParams['threshold_db_per_band'],
      'attack_ms_per_band': List.filled(6, dspParams['attack_ms']),
      'release_ms_per_band': List.filled(6, dspParams['release_ms']),
      'soft_limiter_threshold': dspParams['limiter_threshold'],
      'wet_mix': dspParams['wet_mix'],
      'dry_mix': dspParams['dry_mix'],
    };
    await File(
      '${paths.metadata}/dsp_config.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(dspConfig));

    const bandLabels = ['band1', 'band2', 'band3', 'band4', 'band5', 'band6'];
    const freqRegions = [
      '<500', '500-1000', '1000-2000', '2000-4000', '4000-8000', '>8000',
    ];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final buf = StringBuffer(
      'timestamp_ms,band_index,band_label,frequency_region,gain_db,gain_linear,source,mode\n',
    );
    for (int i = 0; i < 6; i++) {
      buf.writeln(
        '$nowMs,$i,${bandLabels[i]},${freqRegions[i]},${gainsDb[i]},'
        '${_dbToLinear(gainsDb[i])},hearing_profile,$modeLabel',
      );
    }
    await File('${paths.metadata}/gain_profile.csv').writeAsString(buf.toString());

    final modeCsv = StringBuffer(
      'mode,band_index,threshold_db,ratio,attack_ms,release_ms\n',
    );
    const modeNames = ['Standard', 'Transit', 'Conversation'];
    for (int m = 0; m < 3; m++) {
      final p = _engine.getDspConfigForProfile(
        loss6: loss6,
        mode: m,
        sampleRate: kEvidenceSampleRate,
      );
      final thr = p['threshold_db_per_band'] as List;
      for (int b = 0; b < 6; b++) {
        modeCsv.writeln(
          '${modeNames[m]},$b,${thr[b]},${p['ratio']},${p['attack_ms']},${p['release_ms']}',
        );
      }
    }
    await File('${paths.metadata}/mode_config.csv').writeAsString(modeCsv.toString());
  }

  double _dbToLinear(double db) => math.pow(10.0, db / 20.0).toDouble();

  // ---- Live microphone capture --------------------------------------------

  Future<void> startLiveCapture(
    SessionPaths paths, {
    required int mode,
    int durationSeconds = 30,
  }) {
    return Future(
      () => _engine.evidenceStart(
        sessionId: paths.sessionId,
        experimentType: EvidenceExperimentType.liveMicrophoneTest.code,
        mode: mode,
        durationSeconds: durationSeconds,
        captureRawProcessed: true,
        captureBandLog: true,
        captureLimiterLog: true,
        captureFrameLog: true,
      ),
    );
  }

  Future<int> stopAndFlushLiveCapture(SessionPaths paths) async {
    _engine.evidenceStop();
    return _engine.evidenceFlush(logsDir: paths.logs, audioDir: paths.audio);
  }

  // ---- Phase 7: pure-tone battery -----------------------------------------

  Future<void> runPureToneBattery(
    SessionPaths paths, {
    required List<double> loss6,
    required int mode,
  }) async {
    for (final freq in kPureToneFrequenciesHz) {
      final tag = '${freq.toInt()}Hz';
      final rawPath = '${paths.audio}/pure_tone_raw_$tag.wav';
      final procPath = '${paths.audio}/pure_tone_processed_$tag.wav';
      _engine.generateToneWav(
        path: rawPath,
        freqHz: freq,
        durationSec: 3.0,
        sampleRate: kEvidenceSampleRate,
        amplitudeDbFs: -18.0,
      );
      _engine.processAudioFileFull(
        inPath: rawPath,
        outPath: procPath,
        loss6: loss6,
        mode: mode,
        bandLogCsvPath: '${paths.logs}/band_level_log.csv',
        limiterLogCsvPath: '${paths.logs}/limiter_log.csv',
        sourceLabel: 'pure_tone_$tag',
      );
    }
  }

  // ---- Phase 8: frequency sweep -------------------------------------------

  Future<void> runSweepTest(
    SessionPaths paths, {
    required List<double> loss6,
    required int mode,
  }) async {
    final rawPath = '${paths.audio}/sweep_raw_20_10000Hz.wav';
    final procPath = '${paths.audio}/sweep_processed_20_10000Hz.wav';
    _engine.generateSweepWav(
      path: rawPath,
      f0Hz: 20.0,
      f1Hz: 10000.0,
      durationSec: 10.0,
      sampleRate: kEvidenceSampleRate,
      amplitudeDbFs: -24.0,
    );
    _engine.processAudioFileFull(
      inPath: rawPath,
      outPath: procPath,
      loss6: loss6,
      mode: mode,
      bandLogCsvPath: '${paths.logs}/band_level_log.csv',
      limiterLogCsvPath: '${paths.logs}/limiter_log.csv',
      sourceLabel: 'sweep',
    );
  }

  // ---- Phase 9: mode comparison --------------------------------------------

  Future<void> runModeComparison(
    SessionPaths paths, {
    required List<double> loss6,
  }) async {
    final rawPath = '${paths.audio}/mode_test_raw_input.wav';
    _engine.generateSyntheticTestWav(
      path: rawPath,
      durationSec: 6.0,
      sampleRate: kEvidenceSampleRate,
    );
    const modes = [
      (0, 'standard_mode_processed.wav', 'mode_standard'),
      (1, 'transit_mode_processed.wav', 'mode_transit'),
      (2, 'conversation_mode_processed.wav', 'mode_conversation'),
    ];
    for (final (modeCode, fileName, sourceTag) in modes) {
      _engine.processAudioFileFull(
        inPath: rawPath,
        outPath: '${paths.audio}/$fileName',
        loss6: loss6,
        mode: modeCode,
        bandLogCsvPath: '${paths.logs}/band_level_log.csv',
        limiterLogCsvPath: '${paths.logs}/limiter_log.csv',
        sourceLabel: sourceTag,
      );
    }
  }

  /// Records a gain change into gain_update_log.csv (only recorded while an
  /// evidence session is active -- see evidence.h EvidenceSession::isActive).
  void logGainUpdate(String source, List<double> gainsDb6) {
    _engine.evidenceLogGainUpdate(source, gainsDb6);
  }
}

class SessionPaths {
  final String sessionId;
  final String root;
  SessionPaths({required this.sessionId, required this.root});

  String get metadata => '$root/metadata';
  String get audio => '$root/audio';
  String get logs => '$root/logs';
  String get plots => '$root/plots';
  String get summary => '$root/summary';
}
