import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ---------------------------------------------------------------------------
// Data contract
// ---------------------------------------------------------------------------

class EnvironmentResult {
  /// One of: "Transportation", "Conversation", "Ambient / Unknown",
  ///         "Silence", "Initializing"
  final String mode;

  /// Confidence in [0.0, 1.0].
  final double confidence;

  /// Raw sigmoid output from the model: P(conversation).
  final double rawProb;

  /// RMS of the most recent window used for inference (or the live window
  /// when below the silence threshold).
  final double rms;

  const EnvironmentResult({
    required this.mode,
    required this.confidence,
    required this.rawProb,
    required this.rms,
  });

  static const EnvironmentResult initializing = EnvironmentResult(
    mode: 'Initializing',
    confidence: 0.0,
    rawProb: 0.0,
    rms: 0.0,
  );

  static const EnvironmentResult silence = EnvironmentResult(
    mode: 'Silence',
    confidence: 0.0,
    rawProb: 0.0,
    rms: 0.0,
  );
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class EnvironmentDetectorService {
  // ---- Audio capture constants ----
  static const int _sampleRate = 22050;
  static const int _windowSamples = 88200; // 4 s at 22050 Hz

  // ---- Runtime-adjustable parameters ----
  double silenceThreshold = 0.025;
  double hopSeconds = 1.0;
  bool useVoteSmoothing = true;

  int get _hopSamples => (_sampleRate * hopSeconds).round();

  // ---- Mel spectrogram constants ----
  static const int _nFft = 2048;
  static const int _hopLength = 512;
  static const int _nMels = 128;
  static const int _fMin = 0;
  static const int _fMax = 11025; // Nyquist at 22050 Hz
  static const double _topDb = 80.0;

  // Spectrogram frames: floor((88200 - 2048) / 512) + 1 = 169
  // Padded to 173 to match model input [1, 128, 173, 1].
  static const int _expectedFrames = 173;
  static const double _convThreshold = 0.40; // P(conversation) >= 0.40
  static const int _voteBufferLen = 5;

  // ---- State ----
  final StreamController<EnvironmentResult> _resultCtrl =
      StreamController<EnvironmentResult>.broadcast();

  Stream<EnvironmentResult> get results => _resultCtrl.stream;

  bool _running = false;
  bool get isRunning => _running;

  Interpreter? _interpreter;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _pcmSub;

  /// Circular sample buffer: always holds the latest _windowSamples floats.
  late Float32List _sampleBuf;

  /// How many valid samples are currently in the buffer.
  int _sampleCount = 0;

  /// Counter of newly arrived samples since the last inference.
  int _newSamplesSinceInference = 0;

  /// Majority-vote ring buffer.  Values are raw model outputs (floats).
  final List<double> _voteBuffer = [];

  // ---- Pre-allocated DSP scratch buffers (avoid hot-path allocation) ----
  late Float64List _fftReal;
  late Float64List _fftImag;
  late Float32List _powerSpectrum; // length = _nFft / 2 + 1 = 1025
  late Float64List _hannWindow;    // length = _nFft
  late List<List<double>> _melFilterbank; // [_nMels][1025]

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> start() async {
    if (_running) return;
    _running = true;

    _resultCtrl.add(EnvironmentResult.initializing);

    // Allocate DSP buffers once.
    _sampleBuf = Float32List(_windowSamples);
    _sampleCount = 0;
    _newSamplesSinceInference = 0;
    _fftReal = Float64List(_nFft);
    _fftImag = Float64List(_nFft);
    _powerSpectrum = Float32List(_nFft ~/ 2 + 1);
    _hannWindow = _buildHannWindow(_nFft);
    _melFilterbank = _buildMelFilterbank();

    // Load TFLite model lazily on first start.
    _interpreter ??= await Interpreter.fromAsset(
      'assets/models/cnn_model_v2.tflite',
    );

    // NOTE: EnvironmentDetectorService uses the `record` package (Android
    // AudioRecord) independently from the Oboe real-time stream. Both can
    // acquire the microphone simultaneously only if the device / Android version
    // supports concurrent capture (requires API 29+ and ALLOW_CAPTURE_BY_ALL
    // policy). On older devices they will compete; whichever grabs the mic last
    // wins, which may silence the other. If both are active at the same time
    // expect degraded or muted audio on one stream.
    _recorder = AudioRecorder();
    final pcmStream = await _recorder!.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
    );

    _pcmSub = pcmStream.listen(
      _onPcmChunk,
      onError: (Object e) {
        debugPrint('[EnvDetect] PCM stream error: $e');
      },
    );
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    await _pcmSub?.cancel();
    _pcmSub = null;

    await _recorder?.stop();
    await _recorder?.dispose();
    _recorder = null;

    // Close the interpreter to free TFLite model memory.
    _interpreter?.close();
    _interpreter = null;

    _voteBuffer.clear();
  }

  void dispose() {
    stop();
    _resultCtrl.close();
  }

  // ---------------------------------------------------------------------------
  // PCM ingestion
  // ---------------------------------------------------------------------------

  void _onPcmChunk(Uint8List bytes) {
    if (!_running) return;

    final int sampleCount = bytes.lengthInBytes ~/ 2;
    if (sampleCount == 0) return;
    final ByteData bd = bytes.buffer.asByteData(bytes.offsetInBytes);

    if (_sampleCount < _windowSamples) {
      // Fill phase: buffer is not yet full. Append as many samples as fit,
      // then hand the remainder to the batch-shift path.
      final int canFit = _windowSamples - _sampleCount;
      final int fillCount = math.min(sampleCount, canFit);
      for (int i = 0; i < fillCount; i++) {
        final int raw = bd.getInt16(i * 2, Endian.little);
        _sampleBuf[_sampleCount++] = raw / 32768.0;
      }
      _newSamplesSinceInference += fillCount;

      if (sampleCount > fillCount) {
        // Buffer just became full mid-chunk; process the remaining samples.
        final Uint8List remainder = bytes.sublist(fillCount * 2);
        _onPcmChunk(remainder);
        return;
      }
    } else {
      // Steady state: buffer is full. Batch-shift + append.
      _ingestChunkIntoBuffer(bytes, sampleCount, bd);
      _newSamplesSinceInference += sampleCount;
    }

    // Trigger inference once a full hop (1 s = 22050 samples) has arrived.
    while (_newSamplesSinceInference >= _hopSamples &&
        _sampleCount >= _windowSamples) {
      _newSamplesSinceInference -= _hopSamples;
      _runInference();
    }
  }

  /// Efficient batch ingestion: shift the existing buffer left by `n` positions
  /// and append the `n` new float32 samples from `bd`.
  void _ingestChunkIntoBuffer(Uint8List bytes, int n, ByteData bd) {
    // Clamp to at most a full window shift (discard older data beyond window).
    final int shift = math.min(n, _windowSamples);

    if (shift >= _windowSamples) {
      // Entire window replaced by the most recent _windowSamples samples
      // from this chunk (take the tail of the chunk).
      final int startIdx = n - _windowSamples;
      for (int i = 0; i < _windowSamples; i++) {
        final int raw = bd.getInt16((startIdx + i) * 2, Endian.little);
        _sampleBuf[i] = raw / 32768.0;
      }
    } else {
      // Shift existing data left.
      _sampleBuf.setRange(0, _windowSamples - shift, _sampleBuf, shift);
      // Append new data at the tail.
      for (int i = 0; i < shift; i++) {
        final int raw = bd.getInt16(i * 2, Endian.little);
        _sampleBuf[_windowSamples - shift + i] = raw / 32768.0;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Inference pipeline
  // ---------------------------------------------------------------------------

  void _runInference() {
    // 1. Silence check.
    final double rms = _computeRms(_sampleBuf, 0, _windowSamples);
    if (rms < silenceThreshold) {
      _resultCtrl.add(EnvironmentResult(
        mode: 'Silence',
        confidence: 0.0,
        rawProb: 0.0,
        rms: rms,
      ));
      return;
    }

    // 2. Compute mel spectrogram → power-to-dB → min-max normalize.
    final Float32List melDb = _computeMelSpectrogram(_sampleBuf);

    // 3. Run TFLite inference.
    //    Input tensor: [1, 128, 173, 1]
    //    Output tensor: [1, 1]
    final List<List<List<List<double>>>> input = List.generate(
      1,
      (_) => List.generate(
        _nMels,
        (mel) => List.generate(
          _expectedFrames,
          (t) => [melDb[mel * _expectedFrames + t].toDouble()],
        ),
      ),
    );

    final List<List<double>> output = [[0.0]];

    try {
      _interpreter!.run(input, output);
    } catch (e) {
      debugPrint('[EnvDetect] TFLite run error: $e');
      return;
    }

    final double rawProb = output[0][0].clamp(0.0, 1.0);

    // 4. Majority vote (or raw single-sample when smoothing is disabled).
    String mode;
    double confidence;

    if (!useVoteSmoothing) {
      // Raw mode: classify this window immediately without smoothing.
      if (rawProb >= _convThreshold) {
        mode = 'Conversation';
        confidence = rawProb;
      } else {
        mode = 'Transportation';
        confidence = 1.0 - rawProb;
      }
    } else {
      _voteBuffer.add(rawProb);
      if (_voteBuffer.length > _voteBufferLen) {
        _voteBuffer.removeAt(0);
      }

      final int n = _voteBuffer.length;
      int convCount = 0;
      int transCount = 0;
      for (final p in _voteBuffer) {
        if (p >= _convThreshold) {
          convCount++;
        } else {
          transCount++;
        }
      }
      final double tRatio = transCount / n;
      final double cRatio = convCount / n;

      if (tRatio >= 0.40 && tRatio > cRatio) {
        mode = 'Transportation';
        confidence = 1.0 - rawProb;
      } else if (cRatio >= 0.35 && cRatio > tRatio) {
        mode = 'Conversation';
        confidence = rawProb;
      } else {
        mode = 'Ambient / Unknown';
        confidence = 1.0 - (rawProb - 0.5).abs() * 2.0;
      }
    }

    _resultCtrl.add(EnvironmentResult(
      mode: mode,
      confidence: confidence.clamp(0.0, 1.0),
      rawProb: rawProb,
      rms: rms,
    ));
  }

  // ---------------------------------------------------------------------------
  // DSP: RMS
  // ---------------------------------------------------------------------------

  /// Computes root-mean-square of `buf[start..start+length]`.
  static double _computeRms(Float32List buf, int start, int length) {
    double sum = 0.0;
    for (int i = start; i < start + length; i++) {
      sum += buf[i] * buf[i];
    }
    return math.sqrt(sum / length);
  }

  // ---------------------------------------------------------------------------
  // DSP: Mel spectrogram
  // ---------------------------------------------------------------------------

  /// Full pipeline: samples → mel spectrogram (dB, normalised), returned as a
  /// flat Float32List of length _nMels * _expectedFrames (row-major: mel-first).
  Float32List _computeMelSpectrogram(Float32List samples) {
    // frames = floor((N - nFft) / hopLength) + 1 = 169 for our constants.
    final int rawFrames =
        ((_windowSamples - _nFft) ~/ _hopLength) + 1; // 169

    // Output array: [_nMels x _expectedFrames], initialised to 0.0 so
    // padding (frames 169-172) is handled automatically.
    final Float32List melSpec =
        Float32List(_nMels * _expectedFrames); // zero-initialised

    for (int frame = 0; frame < rawFrames; frame++) {
      final int start = frame * _hopLength;

      // Copy + apply Hann window into FFT buffers (no allocation: reuse fields).
      for (int i = 0; i < _nFft; i++) {
        _fftReal[i] = samples[start + i] * _hannWindow[i];
        _fftImag[i] = 0.0;
      }

      // In-place radix-2 Cooley-Tukey FFT.
      _fftInPlace(_fftReal, _fftImag);

      // Power spectrum (one-sided, length 1025).
      for (int k = 0; k <= _nFft ~/ 2; k++) {
        _powerSpectrum[k] = (_fftReal[k] * _fftReal[k] +
                _fftImag[k] * _fftImag[k])
            .toFloat32();
      }

      // Apply mel filterbank: [_nMels] dot products over power spectrum.
      for (int m = 0; m < _nMels; m++) {
        double energy = 0.0;
        final List<double> filter = _melFilterbank[m];
        for (int k = 0; k < filter.length; k++) {
          energy += filter[k] * _powerSpectrum[k];
        }
        // Power to dB: 10 * log10(S + 1e-9)
        final double db = 10.0 * math.log(energy + 1e-9) / math.ln10;
        melSpec[m * _expectedFrames + frame] = db.toFloat32();
      }
    }
    // Frames [rawFrames.._expectedFrames-1] remain 0.0 (right-pad with zeros).

    // Power-to-dB clipping (top_db=80): find per-sample peak, then clip
    // values below (peak - top_db).
    double peak = -double.infinity;
    for (int i = 0; i < melSpec.length; i++) {
      if (melSpec[i] > peak) peak = melSpec[i];
    }
    final double floor = peak - _topDb;
    for (int i = 0; i < melSpec.length; i++) {
      if (melSpec[i] < floor) melSpec[i] = floor.toFloat32();
    }

    // Min-max normalise per sample (over the entire spectrogram).
    double minVal = double.infinity;
    double maxVal = -double.infinity;
    for (int i = 0; i < melSpec.length; i++) {
      if (melSpec[i] < minVal) minVal = melSpec[i];
      if (melSpec[i] > maxVal) maxVal = melSpec[i];
    }
    final double range = (maxVal - minVal) + 1e-9;
    for (int i = 0; i < melSpec.length; i++) {
      melSpec[i] = ((melSpec[i] - minVal) / range).toFloat32();
    }

    return melSpec;
  }

  // ---------------------------------------------------------------------------
  // DSP: Hann window
  // ---------------------------------------------------------------------------

  /// Returns a Hann window of `length` samples.
  /// w[n] = 0.5 * (1 - cos(2*pi*n / (N-1)))
  static Float64List _buildHannWindow(int length) {
    final Float64List w = Float64List(length);
    final double factor = 2.0 * math.pi / (length - 1);
    for (int n = 0; n < length; n++) {
      w[n] = 0.5 * (1.0 - math.cos(factor * n));
    }
    return w;
  }

  // ---------------------------------------------------------------------------
  // DSP: Mel filterbank (Slaney / librosa default)
  // ---------------------------------------------------------------------------

  /// Builds 128 triangular mel filters over `_nFft/2 + 1 = 1025` FFT bins.
  /// Uses the Slaney mel scale:
  ///   hz_to_mel(f) = 2595 * log10(1 + f / 700)
  ///   mel_to_hz(m) = 700 * (10^(m / 2595) - 1)
  ///
  /// Returns a list of length _nMels, each element a double[] of length 1025.
  static List<List<double>> _buildMelFilterbank() {
    const int numBins = _nFft ~/ 2 + 1; // 1025

    // 130 equally-spaced mel points from mel(_fMin) to mel(_fMax).
    final double melMin = _hzToMel(_fMin.toDouble());
    final double melMax = _hzToMel(_fMax.toDouble());
    final List<double> melPoints = List.generate(
      _nMels + 2,
      (i) => melMin + i * (melMax - melMin) / (_nMels + 1),
    );

    // Convert mel points back to Hz, then to FFT bin indices.
    final List<double> hzPoints = melPoints.map(_melToHz).toList();
    final List<int> binPoints = hzPoints
        .map((hz) => (hz * (_nFft + 1) / _sampleRate).round().clamp(0, numBins - 1))
        .toList();

    // Build triangular filters.
    final List<List<double>> fb = List.generate(_nMels, (_) => List.filled(numBins, 0.0));

    for (int m = 0; m < _nMels; m++) {
      final int lo = binPoints[m];
      final int center = binPoints[m + 1];
      final int hi = binPoints[m + 2];

      // Rising slope: lo..center
      if (center > lo) {
        final double width = (center - lo).toDouble();
        for (int k = lo; k <= center; k++) {
          fb[m][k] = (k - lo) / width;
        }
      }

      // Falling slope: center..hi
      if (hi > center) {
        final double width = (hi - center).toDouble();
        for (int k = center; k <= hi; k++) {
          fb[m][k] = (hi - k) / width;
        }
      }
    }

    return fb;
  }

  static double _hzToMel(double hz) => 2595.0 * math.log(1.0 + hz / 700.0) / math.ln10;
  static double _melToHz(double mel) => 700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);

  // ---------------------------------------------------------------------------
  // DSP: Radix-2 Cooley-Tukey in-place FFT
  //
  // Reference: Cooley & Tukey (1965). Input length must be a power of 2.
  // We use two Float64Lists (real, imag) to avoid heap allocations in the loop.
  //
  // Algorithm overview:
  //   1. Bit-reversal permutation of the input.
  //   2. Butterfly stages: for each stage s = 1..log2(N),
  //      group size M = 2^s, stride M/2.
  //      Twiddle factor W = exp(-j * 2*pi*k / M).
  // ---------------------------------------------------------------------------

  /// In-place radix-2 DIT FFT.  real and imag must have the same power-of-2
  /// length. After the call real[k] and imag[k] hold the k-th complex bin.
  static void _fftInPlace(Float64List real, Float64List imag) {
    final int n = real.length;

    // Bit-reversal permutation.
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        double tmp = real[i]; real[i] = real[j]; real[j] = tmp;
        tmp = imag[i]; imag[i] = imag[j]; imag[j] = tmp;
      }
    }

    // Butterfly stages.
    for (int len = 2; len <= n; len <<= 1) {
      final double ang = -2.0 * math.pi / len;
      final double wRe = math.cos(ang);
      final double wIm = math.sin(ang);

      for (int i = 0; i < n; i += len) {
        double curRe = 1.0;
        double curIm = 0.0;
        final int half = len >> 1;

        for (int k = 0; k < half; k++) {
          final int u = i + k;
          final int v = u + half;

          final double uRe = real[u];
          final double uIm = imag[u];
          final double vRe = curRe * real[v] - curIm * imag[v];
          final double vIm = curRe * imag[v] + curIm * real[v];

          real[u] = uRe + vRe;
          imag[u] = uIm + vIm;
          real[v] = uRe - vRe;
          imag[v] = uIm - vIm;

          // Advance twiddle factor: cur = cur * w.
          final double nextRe = curRe * wRe - curIm * wIm;
          final double nextIm = curRe * wIm + curIm * wRe;
          curRe = nextRe;
          curIm = nextIm;
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Extension: double → float32 (clamp to float range)
// ---------------------------------------------------------------------------
extension _ToFloat32 on double {
  double toFloat32() {
    if (isNaN) return 0.0;
    if (isInfinite) return isNegative ? -3.4028235e38 : 3.4028235e38;
    return this;
  }
}

