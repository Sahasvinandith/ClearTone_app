import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:io';
import 'dart:async';
import '../models/profile.dart';
import '../audio_engine_ffi.dart';
import '../audio_generator.dart';
import '../services/environment_detector.dart';
import '../amplification_status.dart';

class AmplificationScreen extends StatefulWidget {
  final Profile profile;

  const AmplificationScreen({super.key, required this.profile});

  @override
  State<AmplificationScreen> createState() => _AmplificationScreenState();
}

class _AmplificationScreenState extends State<AmplificationScreen> {
  // --- Record Mode State ---
  AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioEngineFFI _audioEngine = AudioEngineFFI();
  final AudioGenerator _audioGenerator = AudioGenerator();
  bool _isRecording = false;
  bool _hasPermission = false;
  List<FileSystemEntity> _recordings = [];
  String? _selectedRecordingPath;
  String? _currentlyPlayingPath;
  bool _isPlaying = false;
  bool _demoBroadbandMode = true;
  bool _isPreparingDemoPlayback = false;
  late List<double> _demoLosses;
  Timer? _demoProcessDebounce;
  int _demoProcessGeneration = 0;
  Duration _playbackPosition = Duration.zero;
  bool _showRecordTools = false;

  // --- Real-time Mode State ---
  static const MethodChannel _audioChannel = MethodChannel(
    'com.cleartone/audio',
  );
  List<Map<String, dynamic>> _audioDevices = [];
  int? _selectedDeviceId;
  bool _isRtStreaming = false;
  bool _isCommunicationMode = true; // Default to VoiceCommunication
  int _environmentMode = 0; // 0=Standard, 1=Transit, 2=Conversation
  bool _expanderEnabled =
      true; // Conversation Mode suppression diagnostic toggle
  bool _isMeasuringLatency = false;
  bool _isMeasuringChirpLatency = false;
  double? _lastLatencyMs;
  double? _lastChirpLatencyMs;
  double? _lastChirpInputScore;
  double? _lastChirpOutputScore;
  Timer? _reconnectTimer;

  // --- Environment Auto-Detection State ---
  bool _envDetectEnabled = false;
  double _envSilenceThreshold = 0.007;
  late final TextEditingController _envSilenceThresholdController;
  double _envHopSize = 1.0;
  EnvironmentDetectorService? _envDetector;
  StreamSubscription<EnvironmentResult>? _envSub;
  String _detectedEnvironment = '';
  double _detectedConfidence = 0.0;
  double _detectedRms = 0.0;
  double _detectedRawProb = 0.0;
  Timer? _conversationHoldTimer;
  int? _pendingMode; // mode waiting to apply after conversation hold expires

  // Real-time sliders
  final List<String> _rtBandLabels = [
    '<500 Hz',
    '500-1k Hz',
    '1-2k Hz',
    '2-4k Hz',
    '4-8k Hz',
    '>8k Hz',
  ];
  late List<double> _rtLosses;

  @override
  void initState() {
    super.initState();
    _checkPermissions().then((_) {
      if (_hasPermission) {
        _fetchAudioDevices();
      }
    });
    _loadRecordings();

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
          if (state == PlayerState.completed) {
            _currentlyPlayingPath = null;
            _isPlaying = false;
            _playbackPosition = Duration.zero;
          }
        });
      }
    });
    _audioPlayer.onPositionChanged.listen((position) {
      _playbackPosition = position;
    });

    _envSilenceThresholdController = TextEditingController(
      text: _envSilenceThreshold.toStringAsFixed(3),
    );
    _initRtGainFromProfile();
    _demoLosses = List<double>.from(_rtLosses);
    _startReconnectTimer();
    amplificationController.register(
      setStreaming: _setRtStreaming,
      setEnvironmentDetection: _toggleEnvDetection,
      setEnvironmentMode: _onEnvironmentModeChanged,
    );
    _publishAmplificationStatus();
  }

  @override
  void dispose() {
    amplificationController.unregister();
    _reconnectTimer?.cancel();
    if (_isRtStreaming) {
      _audioEngine.stopRtStream();
      _stopAmplificationForegroundService();
      _hideAmplificationOverlay(resetDismissed: true);
      amplificationStatusNotifier.value = amplificationStatusNotifier.value
          .copyWith(isStreaming: false);
    }
    _envSub?.cancel();
    _conversationHoldTimer?.cancel();
    _demoProcessDebounce?.cancel();
    _audioEngine.stopLatencyProbe();
    unawaited(_audioGenerator.stopTone());
    _envDetector?.stop().then((_) => _envDetector?.dispose());
    _envSilenceThresholdController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _toggleEnvDetection(bool enabled) async {
    if (enabled) {
      if (!_isRtStreaming) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Start real-time amplification before enabling Auto Detect.',
            ),
          ),
        );
        return;
      }
      _envDetector = EnvironmentDetectorService();
      _envDetector!.silenceThreshold = _envSilenceThreshold;
      _envDetector!.hopSeconds = _envHopSize;
      _envSub = _envDetector!.results.listen(_onEnvResult);
      await _envDetector!.start();
      if (mounted) {
        setState(() => _envDetectEnabled = true);
        _publishAmplificationStatus();
      }
    } else {
      _envSub?.cancel();
      _conversationHoldTimer?.cancel();
      _conversationHoldTimer = null;
      _pendingMode = null;
      await _envDetector?.stop();
      _envDetector?.dispose();
      _envDetector = null;
      _envSub = null;
      if (mounted) {
        setState(() {
          _envDetectEnabled = false;
          _detectedEnvironment = '';
          _detectedConfidence = 0.0;
          _detectedRms = 0.0;
          _detectedRawProb = 0.0;
        });
        _publishAmplificationStatus();
      }
    }
  }

  void _publishAmplificationStatus() {
    amplificationStatusNotifier.value = AmplificationStatus(
      isStreaming: _isRtStreaming,
      isEnvironmentDetectionEnabled: _envDetectEnabled,
      mode: _environmentMode,
      detectedEnvironment: _detectedEnvironment,
      confidence: _detectedConfidence,
      isControllerReady: amplificationController.isReady,
    );
    if (_isRtStreaming) {
      unawaited(_updateAmplificationOverlay());
    }
  }

  void _applyMode(int mode) {
    if (!mounted) return;
    setState(() {
      _environmentMode = mode;
      _expanderEnabled = true;
    });
    if (_isRtStreaming) {
      _audioEngine.setEnvironmentMode(mode);
      if (mode == 2) _audioEngine.setExpanderEnabled(true);
    }
    _publishAmplificationStatus();
  }

  void _onEnvResult(EnvironmentResult result) {
    if (!mounted || !_envDetectEnabled) return;

    int newMode;
    switch (result.mode) {
      case 'Silence':
      case 'Ambient / Unknown':
        newMode = 0;
        break;
      case 'Conversation':
        newMode = 2;
        break;
      case 'Transportation':
        newMode = 1;
        break;
      default:
        // 'Initializing' — update display only, don't touch the mode
        setState(() {
          _detectedEnvironment = result.mode;
          _detectedConfidence = result.confidence;
          _detectedRms = result.rms;
          _detectedRawProb = result.rawProb;
        });
        _publishAmplificationStatus();
        return;
    }

    setState(() {
      _detectedEnvironment = result.mode;
      _detectedConfidence = result.confidence;
      _detectedRms = result.rms;
      _detectedRawProb = result.rawProb;
    });
    _publishAmplificationStatus();

    if (newMode == 2) {
      // Conversation detected: apply immediately and cancel any pending exit
      _conversationHoldTimer?.cancel();
      _conversationHoldTimer = null;
      _pendingMode = null;
      if (newMode != _environmentMode) _applyMode(newMode);
    } else if (_environmentMode == 2) {
      // Leaving conversation: hold for 2 s before switching
      _pendingMode = newMode;
      _conversationHoldTimer ??= Timer(const Duration(seconds: 4), () {
        _conversationHoldTimer = null;
        if (mounted && _envDetectEnabled && _pendingMode != null) {
          _applyMode(_pendingMode!);
          _pendingMode = null;
        }
      });
    } else {
      // Neither entering nor leaving conversation: switch immediately
      _conversationHoldTimer?.cancel();
      _conversationHoldTimer = null;
      _pendingMode = null;
      if (newMode != _environmentMode) _applyMode(newMode);
    }
  }

  void _startReconnectTimer() {
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isRtStreaming) {
        bool actuallyPlaying = _audioEngine.isPlaying();
        if (!actuallyPlaying) {
          debugPrint(
            "Audio engine stopped unexpectedly. Attempting restart...",
          );

          // Stop and Restart Oboe Stream
          _audioEngine.stopRtStream();

          // Re-enable SCO only if a BT SCO device is selected
          final reconnectDevice = _audioDevices.firstWhere(
            (d) => d['id'] == _selectedDeviceId,
            orElse: () => {},
          );
          final bool reconnectDeviceIsBtSco =
              (reconnectDevice['type'] as int? ?? -1) == 7;
          if (_isCommunicationMode && reconnectDeviceIsBtSco) {
            try {
              await _audioChannel.invokeMethod('enableBluetoothSco', {
                'enable': true,
              });
              await Future.delayed(const Duration(milliseconds: 500));
            } catch (e) {
              debugPrint("Error re-enabling Bluetooth SCO: $e");
            }
          }

          _audioEngine.setEnvironmentMode(_environmentMode);
          int result = _audioEngine.startRtStream(_selectedDeviceId ?? 0);
          if (result == 0) {
            _audioEngine.updateRtParams(_rtLosses);
            debugPrint("Auto-restart successful.");
          }
        }
      }
    });
  }

  void _initRtGainFromProfile() {
    // Start with the loss from the user profile, but make it controllable
    if (widget.profile.testResults.isNotEmpty) {
      final latestResult = widget.profile.testResults.last;
      final leftResults = latestResult.leftEarResults;
      final rightResults = latestResult.rightEarResults;
      final bool leftSkipped = leftResults.isEmpty;
      final bool rightSkipped = rightResults.isEmpty;

      // Use whichever ear has data to get the frequency key list
      List<int> sortedFreqs =
          (!leftSkipped ? leftResults.keys : rightResults.keys).toList()
            ..sort();

      List<double> avgLoss = [];
      for (int freq in sortedFreqs) {
        if (leftSkipped) {
          avgLoss.add(rightResults[freq]?.toDouble() ?? 0.0);
        } else if (rightSkipped) {
          avgLoss.add(leftResults[freq]?.toDouble() ?? 0.0);
        } else {
          double left = leftResults[freq]?.toDouble() ?? 0.0;
          double right = rightResults[freq]?.toDouble() ?? 0.0;
          avgLoss.add((left + right) / 2.0);
        }
      }

      while (avgLoss.length < 6) {
        avgLoss.add(0.0);
      }
      if (avgLoss.length > 6) avgLoss = avgLoss.sublist(0, 6);
      _rtLosses = avgLoss;
    } else {
      _rtLosses = List.filled(6, 0.0);
    }
  }

  // --- Real-time Methods ---

  Future<void> _fetchAudioDevices() async {
    try {
      if (Platform.isAndroid) {
        final List<dynamic> devices = await _audioChannel.invokeMethod(
          'getAudioInputDevices',
        );
        setState(() {
          _audioDevices = devices
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          if (_audioDevices.isNotEmpty && _selectedDeviceId == null) {
            _selectedDeviceId = _audioDevices.first['id'] as int;
          }
        });
      }
    } on PlatformException catch (e) {
      debugPrint("Failed to get audio devices: '${e.message}'.");
    }
  }

  Future<void> _setRtStreaming(bool enabled) async {
    if (_isRtStreaming == enabled) return;
    await _toggleRtStream();
  }

  Future<void> _requestAmplificationNotificationPermission() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.notification.status;
    if (status.isDenied || status.isRestricted || status.isLimited) {
      await Permission.notification.request();
    }
  }

  String get _overlayModeLabel {
    switch (_environmentMode) {
      case 1:
        return 'Transit';
      case 2:
        return 'Conversation';
      default:
        return 'Standard';
    }
  }

  String _environmentDisplayLabel(String environment) {
    switch (environment) {
      case 'Silence':
        return 'Standard';
      case 'Transportation':
        return 'Transit';
      default:
        return environment;
    }
  }

  Map<String, Object> get _overlayPayload => {
    'mode': _overlayModeLabel,
    'autoDetectEnabled': _envDetectEnabled,
    'detectedEnvironment': _environmentDisplayLabel(_detectedEnvironment),
    'confidence': _detectedConfidence,
  };

  Future<bool> _canDrawAmplificationOverlay() async {
    if (!Platform.isAndroid) return false;
    return await _audioChannel.invokeMethod<bool>(
          'canDrawAmplificationOverlay',
        ) ??
        false;
  }

  Future<void> _requestAmplificationOverlayPermission() async {
    if (!Platform.isAndroid) return;
    await _audioChannel.invokeMethod('requestAmplificationOverlayPermission');
  }

  Future<void> _ensureAmplificationOverlayPermission() async {
    if (!Platform.isAndroid) return;
    if (await _canDrawAmplificationOverlay()) return;

    await _requestAmplificationOverlayPermission();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Enable "Display over other apps" to show the amplification overlay.',
        ),
      ),
    );
  }

  Future<void> _showAmplificationOverlay() async {
    if (!Platform.isAndroid) return;
    if (!await _canDrawAmplificationOverlay()) return;
    try {
      await _audioChannel.invokeMethod(
        'showAmplificationOverlay',
        _overlayPayload,
      );
    } catch (e) {
      debugPrint("Error showing amplification overlay: $e");
    }
  }

  Future<void> _updateAmplificationOverlay() async {
    if (!Platform.isAndroid) return;
    try {
      await _audioChannel.invokeMethod(
        'updateAmplificationOverlay',
        _overlayPayload,
      );
    } catch (e) {
      debugPrint("Error updating amplification overlay: $e");
    }
  }

  Future<void> _hideAmplificationOverlay({bool resetDismissed = true}) async {
    if (!Platform.isAndroid) return;
    try {
      await _audioChannel.invokeMethod('hideAmplificationOverlay', {
        'resetDismissed': resetDismissed,
      });
    } catch (e) {
      debugPrint("Error hiding amplification overlay: $e");
    }
  }

  Future<void> _startAmplificationForegroundService() async {
    if (!Platform.isAndroid) return;
    await _audioChannel.invokeMethod('startAmplificationForegroundService');
  }

  Future<void> _stopAmplificationForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _audioChannel.invokeMethod('stopAmplificationForegroundService');
    } catch (e) {
      debugPrint("Error stopping amplification foreground service: $e");
    }
  }

  Future<void> _toggleRtStream() async {
    if (_isRtStreaming) {
      _audioEngine.stopRtStream();
      _audioEngine.stopLatencyProbe();
      await _stopAmplificationForegroundService();
      await _hideAmplificationOverlay(resetDismissed: true);
      if (_envDetectEnabled) {
        await _toggleEnvDetection(false);
      }
      // Only stop SCO if it was started (i.e. a BT SCO device is/was selected)
      final stoppingDevice = _audioDevices.firstWhere(
        (d) => d['id'] == _selectedDeviceId,
        orElse: () => {},
      );
      final bool stoppingDeviceIsBtSco =
          (stoppingDevice['type'] as int? ?? -1) == 7;
      if (_isCommunicationMode && stoppingDeviceIsBtSco) {
        try {
          await _audioChannel.invokeMethod('enableBluetoothSco', {
            'enable': false,
          });
        } catch (e) {
          debugPrint("Error disabling Bluetooth SCO: $e");
        }
      }
      setState(() {
        _isRtStreaming = false;
        _isMeasuringLatency = false;
        _isMeasuringChirpLatency = false;
      });
      _publishAmplificationStatus();
    } else {
      if (_selectedDeviceId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a microphone first.')),
        );
        return;
      }

      await _requestAmplificationNotificationPermission();
      await _ensureAmplificationOverlayPermission();

      // 1. Enable Bluetooth SCO only when the selected device is a BT SCO
      //    device (TYPE_BLUETOOTH_SCO = 7). When the user picks the built-in
      //    mic, startBluetoothSco() must NOT be called — Android's SCO is a
      //    paired bidirectional channel and forcibly routes the input to the
      //    headset mic, overriding any deviceId passed to Oboe/AAudio.
      final selectedDevice = _audioDevices.firstWhere(
        (d) => d['id'] == _selectedDeviceId,
        orElse: () => {},
      );
      final bool selectedDeviceIsBtSco =
          (selectedDevice['type'] as int? ?? -1) ==
          7; // AudioDeviceInfo.TYPE_BLUETOOTH_SCO

      if (_isCommunicationMode && selectedDeviceIsBtSco) {
        try {
          await _audioChannel.invokeMethod('enableBluetoothSco', {
            'enable': true,
          });
          // Small delay to allow SCO to stabilize
          await Future.delayed(const Duration(milliseconds: 500));
        } catch (e) {
          debugPrint("Error enabling Bluetooth SCO: $e");
        }
      }

      // 2. Configure usage
      _audioEngine.setAudioUsage(_isCommunicationMode ? 2 : 1);

      // 3. Push the current mode before Oboe opens so the first callback uses
      //    the correct preset and DSP mode.
      _audioEngine.setEnvironmentMode(_environmentMode);

      // 4. Start Oboe Stream
      int result = _audioEngine.startRtStream(_selectedDeviceId!);
      debugPrint("Result: $result");
      if (result == 0) {
        try {
          await _startAmplificationForegroundService();
          if (!mounted) {
            _audioEngine.stopRtStream();
            await _stopAmplificationForegroundService();
            return;
          }
          _audioEngine.updateRtParams(_rtLosses);
          setState(() {
            _isRtStreaming = true;
          });
          _publishAmplificationStatus();
          await _showAmplificationOverlay();
        } catch (e) {
          _audioEngine.stopRtStream();
          await _stopAmplificationForegroundService();
          await _hideAmplificationOverlay(resetDismissed: true);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Amplification started, but background mode could not be enabled: $e',
              ),
            ),
          );
        }
      } else {
        if (!mounted) return;
        // ... (rest of error handling)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to start real-time stream (Code $result). Check device logs.',
            ),
          ),
        );
      }
    }
  }

  void _onRtLossChanged(int index, double newLoss) {
    setState(() {
      _rtLosses[index] = newLoss;
    });
    if (_isRtStreaming) {
      _audioEngine.updateRtParams(_rtLosses);
    }
  }

  void _onEnvironmentModeChanged(int mode) {
    setState(() {
      _environmentMode = mode;
      _expanderEnabled = true; // reset to default when switching modes
    });
    _audioEngine.setEnvironmentMode(mode);
    _publishAmplificationStatus();
  }

  void _onSilenceThresholdTextChanged(String value) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || !parsed.isFinite || parsed <= 0) return;

    setState(() {
      _envSilenceThreshold = parsed;
    });
    _envDetector?.silenceThreshold = parsed;
  }

  Future<void> _verifyInputFeed() async {
    if (!_isRtStreaming) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Start streaming first to verify feed.')),
      );
      return;
    }

    try {
      final directory = await getExternalStorageDirectory();
      if (directory == null) return;
      if (!mounted) return;

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final inputPath = '${directory.path}/input_verify_$timestamp.raw';
      final outputPath = '${directory.path}/output_verify_$timestamp.raw';

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Capturing 3 seconds of Input & Output...'),
        ),
      );

      _audioEngine.debugStartCapture();
      await Future.delayed(const Duration(seconds: 3));
      _audioEngine.debugStopCapture();

      _audioEngine.debugSaveCapture(inputPath, 0);
      _audioEngine.debugSaveCapture(outputPath, 1);
      final size = _audioEngine.debugGetCaptureSize();

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1C),
          title: const Text('Dual Capture Complete'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Samples captured: $size',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                const Text(
                  'INPUT (Mic):',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SelectableText(
                  inputPath,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFD4AF37),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'OUTPUT (Amplified):',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SelectableText(
                  outputPath,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFD4AF37),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Use "adb pull" to retrieve both files and compare them in Audacity.',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Verification error: $e')));
    }
  }

  Future<void> _measureRtLatency() async {
    if (!_isRtStreaming) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start streaming first to measure latency.'),
        ),
      );
      return;
    }
    if (_isMeasuringLatency) return;

    final double triggerThreshold = _envSilenceThreshold
        .clamp(0.0001, 1.0)
        .toDouble();
    setState(() {
      _isMeasuringLatency = true;
      _lastLatencyMs = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Latency probe armed. Play a loud sound above ${triggerThreshold.toStringAsFixed(4)}.',
        ),
      ),
    );

    _audioEngine.startLatencyProbe(triggerThreshold);
    const int pollMs = 50;
    const int timeoutMs = 5000;
    int elapsedMs = 0;

    while (mounted && elapsedMs < timeoutMs) {
      await Future.delayed(const Duration(milliseconds: pollMs));
      elapsedMs += pollMs;

      final status = _audioEngine.getLatencyProbeStatus();
      if (status == 1) {
        final latencyMs = _audioEngine.getLatencyProbeMs();
        if (!mounted) return;
        setState(() {
          _isMeasuringLatency = false;
          _lastLatencyMs = latencyMs;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Measured latency: ${latencyMs.toStringAsFixed(2)} ms',
            ),
          ),
        );
        return;
      }
      if (status == -2) {
        _audioEngine.stopLatencyProbe();
        if (!mounted) return;
        setState(() => _isMeasuringLatency = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Latency probe failed: stream timestamp unavailable.',
            ),
          ),
        );
        return;
      }
    }

    _audioEngine.stopLatencyProbe();
    if (!mounted) return;
    setState(() => _isMeasuringLatency = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Latency probe timed out. Try a louder, sharper sound.'),
      ),
    );
  }

  Future<void> _measureChirpRtLatency() async {
    if (!_isRtStreaming) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Start streaming first to measure chirp latency.'),
        ),
      );
      return;
    }
    if (_isMeasuringLatency || _isMeasuringChirpLatency) return;

    setState(() {
      _isMeasuringChirpLatency = true;
      _lastChirpLatencyMs = null;
      _lastChirpInputScore = null;
      _lastChirpOutputScore = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Chirp probe running. Keep the phone speaker near the mic.',
        ),
      ),
    );

    try {
      _audioEngine.startChirpLatencyProbe(captureMs: 1000);
      await Future.delayed(const Duration(milliseconds: 80));
      await _audioGenerator.playLatencyChirp();
      await Future.delayed(const Duration(milliseconds: 900));

      final status = _audioEngine.stopChirpLatencyProbe();
      final latencyMs = _audioEngine.getChirpLatencyMs();
      final inputScore = _audioEngine.getChirpInputScore();
      final outputScore = _audioEngine.getChirpOutputScore();

      if (!mounted) return;
      setState(() {
        _isMeasuringChirpLatency = false;
        _lastChirpInputScore = inputScore;
        _lastChirpOutputScore = outputScore;
        _lastChirpLatencyMs = status == 1 ? latencyMs : null;
      });

      final message = status == 1
          ? 'Chirp latency: ${latencyMs.toStringAsFixed(2)} ms '
                '(in ${inputScore.toStringAsFixed(2)}, out ${outputScore.toStringAsFixed(2)})'
          : status == -2
          ? 'Chirp probe failed: stream timestamp unavailable.'
          : 'Chirp not matched confidently '
                '(in ${inputScore.toStringAsFixed(2)}, out ${outputScore.toStringAsFixed(2)}).';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      _audioEngine.stopChirpLatencyProbe();
      if (!mounted) return;
      setState(() => _isMeasuringChirpLatency = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Chirp latency error: $e')));
    } finally {
      unawaited(_audioGenerator.stopTone());
    }
  }

  // --- Record Methods ---

  Future<void> _checkPermissions() async {
    final status = await Permission.microphone.request();
    if (mounted) {
      setState(() {
        _hasPermission = status.isGranted;
      });
    }
  }

  Future<void> _loadRecordings() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final files = directory.listSync().toList();
      final profileRecordings = files.where((file) {
        final filename = file.path.split('/').last;
        return filename.startsWith('amplification_${widget.profile.name}_') &&
            !filename.contains('_processed') &&
            !filename.contains('_demo_') &&
            filename.endsWith('.wav');
      }).toList();

      profileRecordings.sort((a, b) {
        final aStat = File(a.path).statSync();
        final bStat = File(b.path).statSync();
        return bStat.modified.compareTo(aStat.modified);
      });

      if (mounted) {
        setState(() {
          _recordings = profileRecordings;
          if (_selectedRecordingPath != null &&
              !_recordings.any((file) => file.path == _selectedRecordingPath)) {
            _selectedRecordingPath = null;
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading recordings: $e');
    }
  }

  Future<void> _startRecording() async {
    if (!_hasPermission) {
      await _checkPermissions();
      if (!_hasPermission) return;
    }

    try {
      debugPrint("Recording started.");
      final directory = await getApplicationDocumentsDirectory();
      final path =
          '${directory.path}/amplification_${widget.profile.name}_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 48000,
          numChannels: 1,
        ),
        path: path,
      );

      if (mounted) {
        setState(() {
          _isRecording = true;
        });
      }
    } catch (e) {
      debugPrint('Error starting record: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      await _audioRecorder.stop();

      // Dispose the recorder to force release of the Bluetooth SCO channel / Mic focus
      await _audioRecorder.dispose();
      _audioRecorder = AudioRecorder();

      if (mounted) {
        setState(() {
          _isRecording = false;
        });
        _loadRecordings();
      }
    } catch (e) {
      debugPrint('Error stopping record: $e');
    }
  }

  Future<void> _togglePlayback(String path) async {
    if (_currentlyPlayingPath == path && _isPlaying) {
      await _audioPlayer.pause();
    } else {
      if (_currentlyPlayingPath != path) {
        await _audioPlayer.stop();

        // Force playback routing to media (fixes earbud/communication routing issues after recording)
        await _audioPlayer.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              isSpeakerphoneOn: false,
              stayAwake: true,
              contentType: AndroidContentType.music,
              usageType: AndroidUsageType.media,
              audioFocus: AndroidAudioFocus.gain,
            ),
          ),
        );

        await _audioPlayer.play(DeviceFileSource(path));
        if (mounted) {
          setState(() {
            _currentlyPlayingPath = path;
          });
        }
      } else {
        await _audioPlayer.resume();
      }
    }
  }

  void _selectRecording(String path) {
    setState(() {
      _selectedRecordingPath = _selectedRecordingPath == path ? null : path;
    });
    if (_selectedRecordingPath == path) {
      _prepareDemoPlayback(restartIfPlaying: false);
    }
  }

  String _demoOutputPath(String inputPath) {
    final suffix = _demoBroadbandMode ? 'broadband' : 'multiband';
    return inputPath.replaceAll('.wav', '_demo_$suffix.wav');
  }

  void _onDemoModeChanged(bool broadbandMode) {
    setState(() {
      _demoBroadbandMode = broadbandMode;
      if (broadbandMode) {
        _demoLosses = List<double>.filled(6, _demoLosses.first);
      }
    });
    _prepareDemoPlayback(restartIfPlaying: _isPlaying);
  }

  void _onDemoLossChanged(int index, double value) {
    setState(() {
      if (_demoBroadbandMode) {
        _demoLosses = List<double>.filled(6, value);
      } else {
        _demoLosses[index] = value;
      }
    });

    _demoProcessDebounce?.cancel();
    _demoProcessDebounce = Timer(const Duration(milliseconds: 220), () {
      _prepareDemoPlayback(restartIfPlaying: _isPlaying);
    });
  }

  Future<void> _toggleDemoPlayback({required bool amplified}) async {
    final selectedPath = _selectedRecordingPath;
    if (selectedPath == null) return;

    if (!amplified) {
      await _togglePlayback(selectedPath);
      return;
    }

    final outPath = await _prepareDemoPlayback(restartIfPlaying: false);
    if (outPath == null) return;
    await _togglePlayback(outPath);
  }

  Future<String?> _prepareDemoPlayback({required bool restartIfPlaying}) async {
    final inputPath = _selectedRecordingPath;
    if (inputPath == null || _isPreparingDemoPlayback) {
      return inputPath == null ? null : _demoOutputPath(inputPath);
    }

    final generation = ++_demoProcessGeneration;
    final outPath = _demoOutputPath(inputPath);
    final wasPlayingDemo =
        restartIfPlaying &&
        _currentlyPlayingPath != null &&
        _currentlyPlayingPath == outPath &&
        _isPlaying;
    final resumePosition = _playbackPosition;

    if (mounted) {
      setState(() {
        _isPreparingDemoPlayback = true;
      });
    }

    try {
      if (wasPlayingDemo) {
        await _audioPlayer.stop();
      }

      final result = _audioEngine.processAudio(
        inPath: inputPath,
        outPath: outPath,
        loss6: _demoLosses,
      );
      if (result != 0) {
        throw Exception('Audio engine returned error code: $result');
      }

      if (generation == _demoProcessGeneration && wasPlayingDemo) {
        await _audioPlayer.play(DeviceFileSource(outPath));
        if (resumePosition > Duration.zero) {
          await _audioPlayer.seek(resumePosition);
        }
        if (mounted) {
          setState(() {
            _currentlyPlayingPath = outPath;
          });
        }
      }

      return outPath;
    } catch (e) {
      debugPrint('Error preparing demo playback: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not prepare amplified playback: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    } finally {
      if (mounted && generation == _demoProcessGeneration) {
        setState(() {
          _isPreparingDemoPlayback = false;
        });
      }
    }
  }

  Future<void> _deleteRecording(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        final broadbandPath = path.replaceAll('.wav', '_demo_broadband.wav');
        final multibandPath = path.replaceAll('.wav', '_demo_multiband.wav');
        final generatedFiles = [File(broadbandPath), File(multibandPath)];
        for (final generatedFile in generatedFiles) {
          if (await generatedFile.exists()) {
            await generatedFile.delete();
          }
        }
        if (_currentlyPlayingPath == path ||
            _currentlyPlayingPath == broadbandPath ||
            _currentlyPlayingPath == multibandPath) {
          await _audioPlayer.stop();
          if (mounted) {
            setState(() {
              _currentlyPlayingPath = null;
              _isPlaying = false;
            });
          }
        }
        if (_selectedRecordingPath == path) {
          setState(() {
            _selectedRecordingPath = null;
          });
        }
        _loadRecordings();
      }
    } catch (e) {
      debugPrint('Error deleting file: $e');
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // --- UI Builders ---

  Widget _buildEnvMetric(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF777777),
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFD4AF37),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecordTab() {
    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              vertical: 32.0,
              horizontal: 24.0,
            ),
            color: const Color(0xFF1C1C1C),
            child: Column(
              children: [
                const Icon(
                  Icons.mic_none_outlined,
                  size: 64,
                  color: Color(0xFFD4AF37),
                ),
                const SizedBox(height: 24),
                Text(
                  _isRecording ? 'RECORDING...' : 'READY TO RECORD',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    letterSpacing: 2,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 32),
                GestureDetector(
                  onTap: _isRecording ? _stopRecording : _startRecording,
                  child: Container(
                    height: 80,
                    width: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isRecording
                          ? Colors.red.withValues(alpha: 0.2)
                          : const Color(0xFF282828),
                      border: Border.all(
                        color: _isRecording
                            ? Colors.red
                            : const Color(0xFFD4AF37),
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: Container(
                        height: _isRecording ? 24 : 64,
                        width: _isRecording ? 24 : 64,
                        decoration: BoxDecoration(
                          shape: _isRecording
                              ? BoxShape.rectangle
                              : BoxShape.circle,
                          borderRadius: _isRecording
                              ? BorderRadius.circular(4)
                              : null,
                          color: _isRecording
                              ? Colors.red
                              : const Color(0xFFD4AF37),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isRecording ? 'TAP TO STOP' : 'TAP TO RECORD',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF666666),
                    letterSpacing: 1,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_recordings.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 48.0),
              child: Center(
                child: Text(
                  'NO RECORDINGS YET',
                  style: TextStyle(
                    color: Color(0xFF666666),
                    letterSpacing: 1.5,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _recordings.length,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemBuilder: (context, index) {
                final file = _recordings[index];
                final stat = File(file.path).statSync();
                final demoPath = _demoOutputPath(file.path);
                final isSelected = _selectedRecordingPath == file.path;
                final isCurrentlyPlaying =
                    _currentlyPlayingPath == file.path ||
                    _currentlyPlayingPath == demoPath;
                final isOriginalPlaying =
                    _currentlyPlayingPath == file.path && _isPlaying;
                final isAmplifiedPlaying =
                    _currentlyPlayingPath == demoPath && _isPlaying;
                final filename = file.path.split('/').last;

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected || isCurrentlyPlaying
                          ? const Color(0xFFD4AF37)
                          : Colors.transparent,
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Column(
                      children: [
                        InkWell(
                          onTap: () => _selectRecording(file.path),
                          borderRadius: BorderRadius.circular(10),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: isSelected
                                    ? const Color(
                                        0xFFD4AF37,
                                      ).withValues(alpha: 0.2)
                                    : const Color(0xFF282828),
                                child: Icon(
                                  isSelected ? Icons.tune : Icons.graphic_eq,
                                  color: isSelected
                                      ? const Color(0xFFD4AF37)
                                      : Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      filename,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.calendar_today_outlined,
                                          size: 12,
                                          color: Color(0xFF666666),
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            _formatDateTime(stat.modified),
                                            style: const TextStyle(
                                              color: Color(0xFF666666),
                                              fontSize: 12,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: Icon(
                                  isSelected
                                      ? Icons.keyboard_arrow_up
                                      : Icons.keyboard_arrow_down,
                                  color: const Color(0xFFD4AF37),
                                  size: 28,
                                ),
                                onPressed: () => _selectRecording(file.path),
                                constraints: const BoxConstraints(),
                                padding: const EdgeInsets.all(8),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                  size: 24,
                                ),
                                onPressed: () {
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      backgroundColor: const Color(0xFF1C1C1C),
                                      title: const Text('Delete Recording?'),
                                      content: const Text(
                                        'Are you sure you want to delete this recording?',
                                        style: TextStyle(color: Colors.white70),
                                      ),
                                      actions: [
                                        TextButton(
                                          child: const Text(
                                            'CANCEL',
                                            style: TextStyle(
                                              color: Color(0xFF666666),
                                            ),
                                          ),
                                          onPressed: () =>
                                              Navigator.pop(context),
                                        ),
                                        TextButton(
                                          child: const Text(
                                            'DELETE',
                                            style: TextStyle(
                                              color: Colors.redAccent,
                                            ),
                                          ),
                                          onPressed: () {
                                            Navigator.pop(context);
                                            _deleteRecording(file.path);
                                          },
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        if (isSelected) ...[
                          const SizedBox(height: 14),
                          const Divider(color: Color(0xFF333333), height: 1),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: _buildDemoPlaybackButton(
                                  label: 'Original',
                                  icon: isOriginalPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  active: isOriginalPlaying,
                                  onPressed: () =>
                                      _toggleDemoPlayback(amplified: false),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildDemoPlaybackButton(
                                  label: _isPreparingDemoPlayback
                                      ? 'Preparing'
                                      : 'Amplified',
                                  icon: isAmplifiedPlaying
                                      ? Icons.pause
                                      : Icons.hearing,
                                  active: isAmplifiedPlaying,
                                  onPressed: _isPreparingDemoPlayback
                                      ? null
                                      : () => _toggleDemoPlayback(
                                          amplified: true,
                                        ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF282828),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: const Color(0xFF333333),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: _buildDemoModeButton(
                                    label: 'Broadband',
                                    selected: _demoBroadbandMode,
                                    onTap: () => _onDemoModeChanged(true),
                                  ),
                                ),
                                Expanded(
                                  child: _buildDemoModeButton(
                                    label: 'Multiband',
                                    selected: !_demoBroadbandMode,
                                    onTap: () => _onDemoModeChanged(false),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          ...List.generate(_rtBandLabels.length, (bandIndex) {
                            return _buildDemoGainSlider(bandIndex);
                          }),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  void _openRecordToolsPage() {
    setState(() => _showRecordTools = true);
  }

  Widget _buildDemoPlaybackButton({
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        foregroundColor: active ? Colors.black : const Color(0xFFD4AF37),
        backgroundColor: active ? const Color(0xFFD4AF37) : Colors.transparent,
        side: const BorderSide(color: Color(0xFFD4AF37)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildDemoModeButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFD4AF37) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }

  Widget _buildDemoGainSlider(int index) {
    final value = _demoLosses[index];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(
              _rtBandLabels[index],
              style: const TextStyle(color: Colors.white70, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: const Color(0xFFD4AF37),
                inactiveTrackColor: const Color(0xFF444444),
                thumbColor: const Color(0xFFD4AF37),
                overlayColor: const Color(0xFFD4AF37).withValues(alpha: 0.15),
                trackHeight: 3,
              ),
              child: Slider(
                value: value,
                min: 0,
                max: 60,
                divisions: 60,
                label: '${value.round()} dB',
                onChanged: (newValue) => _onDemoLossChanged(index, newValue),
              ),
            ),
          ),
          SizedBox(
            width: 46,
            child: Text(
              '${value.round()} dB',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFFD4AF37),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRealTimeTab() {
    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(24.0),
            color: const Color(0xFF1C1C1C),
            child: Column(
              children: [
                const Icon(Icons.hearing, size: 48, color: Color(0xFFD4AF37)),
                const SizedBox(height: 16),
                const Text(
                  'REAL-TIME AMPLIFIER',
                  style: TextStyle(
                    color: Colors.white,
                    letterSpacing: 2,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Stream audio from the microphone directly to your earbuds and adjust your hearing loss profile on the fly.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF888888), fontSize: 14),
                ),
                const SizedBox(height: 32),

                // Device Selector
                if (Platform.isAndroid && _audioDevices.isNotEmpty)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'INPUT SOURCE',
                        style: TextStyle(
                          color: Color(0xFF666666),
                          fontSize: 12,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF282828),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF333333)),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: _selectedDeviceId,
                            dropdownColor: const Color(0xFF282828),
                            isExpanded: true,
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              color: Color(0xFFD4AF37),
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            items: _audioDevices.map((device) {
                              return DropdownMenuItem<int>(
                                value: device['id'] as int,
                                child: Text(device['name'] as String),
                              );
                            }).toList(),
                            onChanged: _isRtStreaming
                                ? null
                                : (value) {
                                    setState(() {
                                      _selectedDeviceId = value;
                                    });
                                  },
                          ),
                        ),
                      ),
                      if (_isRtStreaming)
                        const Padding(
                          padding: EdgeInsets.only(top: 8.0),
                          child: Text(
                            'Stop streaming to change microphone.',
                            style: TextStyle(
                              color: Colors.redAccent,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),

                      // Environment Auto-Detect Toggle
                      const Text(
                        'ENVIRONMENT AUTO-DETECT',
                        style: TextStyle(
                          color: Color(0xFF666666),
                          fontSize: 12,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF282828),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _envDetectEnabled
                                ? const Color(0xFFD4AF37).withValues(alpha: 0.5)
                                : const Color(0xFF333333),
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Auto Mode Switching',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      _envDetectEnabled
                                          ? 'Detecting environment...'
                                          : 'Tap to enable adaptive modes',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                                Switch(
                                  value: _envDetectEnabled,
                                  activeThumbColor: const Color(0xFFD4AF37),
                                  onChanged: (value) =>
                                      _toggleEnvDetection(value),
                                ),
                              ],
                            ),
                            if (_envDetectEnabled) ...[
                              const SizedBox(height: 12),
                              const Divider(
                                color: Color(0xFF333333),
                                height: 1,
                              ),
                              const SizedBox(height: 12),
                              // Detected environment indicator
                              Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color:
                                          _detectedEnvironment.isEmpty ||
                                              _detectedEnvironment ==
                                                  'Initializing'
                                          ? Colors.grey
                                          : _detectedEnvironment ==
                                                'Conversation'
                                          ? Colors.greenAccent
                                          : _detectedEnvironment ==
                                                'Transportation'
                                          ? Colors.orangeAccent
                                          : Colors.blueAccent,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _detectedEnvironment.isEmpty
                                        ? 'Waiting for data...'
                                        : _environmentDisplayLabel(
                                            _detectedEnvironment,
                                          ),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (_detectedEnvironment.isNotEmpty &&
                                      _detectedEnvironment != 'Initializing' &&
                                      _detectedEnvironment != 'Silence') ...[
                                    const Spacer(),
                                    Text(
                                      '${(_detectedConfidence * 100).toStringAsFixed(0)}%',
                                      style: const TextStyle(
                                        color: Color(0xFFD4AF37),
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1F1F1F),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFF333333),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: _buildEnvMetric(
                                        'CONF',
                                        '${(_detectedConfidence * 100).toStringAsFixed(1)}%',
                                      ),
                                    ),
                                    Container(
                                      width: 1,
                                      height: 26,
                                      color: const Color(0xFF333333),
                                    ),
                                    Expanded(
                                      child: _buildEnvMetric(
                                        'RMS',
                                        _detectedRms.toStringAsFixed(5),
                                      ),
                                    ),
                                    Container(
                                      width: 1,
                                      height: 26,
                                      color: const Color(0xFF333333),
                                    ),
                                    Expanded(
                                      child: _buildEnvMetric(
                                        'P(CONV)',
                                        _detectedRawProb.toStringAsFixed(3),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              // Silence Threshold input
                              Row(
                                children: [
                                  const SizedBox(
                                    width: 110,
                                    child: Text(
                                      'Silence Threshold',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller:
                                          _envSilenceThresholdController,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'[0-9.]'),
                                        ),
                                      ],
                                      onChanged: _onSilenceThresholdTextChanged,
                                      style: const TextStyle(
                                        color: Color(0xFFD4AF37),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 10,
                                            ),
                                        filled: true,
                                        fillColor: const Color(0xFF1F1F1F),
                                        hintText: '0.007',
                                        hintStyle: const TextStyle(
                                          color: Colors.white30,
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          borderSide: const BorderSide(
                                            color: Color(0xFF333333),
                                          ),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          borderSide: const BorderSide(
                                            color: Color(0xFFD4AF37),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              // Hop Size slider
                              Row(
                                children: [
                                  const SizedBox(
                                    width: 110,
                                    child: Text(
                                      'Hop Size (s)',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderThemeData(
                                        activeTrackColor: const Color(
                                          0xFFD4AF37,
                                        ),
                                        inactiveTrackColor: const Color(
                                          0xFF444444,
                                        ),
                                        thumbColor: const Color(0xFFD4AF37),
                                        overlayColor: const Color(
                                          0xFFD4AF37,
                                        ).withValues(alpha: 0.15),
                                        trackHeight: 3,
                                      ),
                                      child: Slider(
                                        value: _envHopSize,
                                        min: 0.5,
                                        max: 5.0,
                                        divisions: 9,
                                        onChanged: (v) {
                                          setState(() => _envHopSize = v);
                                          _envDetector?.hopSeconds = v;
                                        },
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 40,
                                    child: Text(
                                      '${_envHopSize.toStringAsFixed(1)}s',
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        color: Color(0xFFD4AF37),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Environment Mode Toggle
                      const Text(
                        'ENVIRONMENT MODE',
                        style: TextStyle(
                          color: Color(0xFF666666),
                          fontSize: 12,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_envDetectEnabled)
                        const Text(
                          'Controlled automatically by detector',
                          style: TextStyle(
                            color: Color(0xFFD4AF37),
                            fontSize: 10,
                          ),
                        ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF282828),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF333333)),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: _environmentMode,
                            dropdownColor: const Color(0xFF282828),
                            isExpanded: true,
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              color: Color(0xFFD4AF37),
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 0,
                                child: Text('Standard Mode'),
                              ),
                              DropdownMenuItem(
                                value: 1,
                                child: Text('Transit Mode'),
                              ),
                              DropdownMenuItem(
                                value: 2,
                                child: Text('Conversation Mode'),
                              ),
                            ],
                            onChanged: _envDetectEnabled
                                ? null
                                : (value) {
                                    if (value != null) {
                                      _onEnvironmentModeChanged(value);
                                    }
                                  },
                          ),
                        ),
                      ),
                      if (_environmentMode == 2) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF282828),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF333333)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Own-Voice Suppression',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Text(
                                    _expanderEnabled
                                        ? 'ON - reduces speech feedback'
                                        : 'OFF - bypassed for testing',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                              Switch(
                                value: _expanderEnabled,
                                activeThumbColor: const Color(0xFFD4AF37),
                                onChanged: (value) {
                                  setState(() => _expanderEnabled = value);
                                  _audioEngine.setExpanderEnabled(value);
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),

                      // Audio Mode Toggle
                      const Text(
                        'AUDIO MODE',
                        style: TextStyle(
                          color: Color(0xFF666666),
                          fontSize: 12,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF282828),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF333333)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isCommunicationMode
                                      ? 'Communication Mode'
                                      : 'Media Mode',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  _isCommunicationMode
                                      ? 'Used for Bluetooth Headsets (SCO)'
                                      : 'Better for Wired / Phone Speaker',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            Switch(
                              value: _isCommunicationMode,
                              activeThumbColor: const Color(0xFFD4AF37),
                              onChanged: _isRtStreaming
                                  ? null
                                  : (value) {
                                      setState(() {
                                        _isCommunicationMode = value;
                                      });
                                    },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                const SizedBox(height: 48),

                // Power Button
                GestureDetector(
                  onTap: _toggleRtStream,
                  child: Container(
                    height: 100,
                    width: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isRtStreaming
                          ? Colors.red.withValues(alpha: 0.1)
                          : const Color(0xFFD4AF37).withValues(alpha: 0.1),
                      border: Border.all(
                        color: _isRtStreaming
                            ? Colors.red
                            : const Color(0xFFD4AF37),
                        width: 3,
                      ),
                      boxShadow: _isRtStreaming
                          ? [
                              BoxShadow(
                                color: Colors.red.withValues(alpha: 0.3),
                                blurRadius: 15,
                                spreadRadius: 2,
                              ),
                            ]
                          : [],
                    ),
                    child: Center(
                      child: Icon(
                        Icons.power_settings_new,
                        size: 48,
                        color: _isRtStreaming
                            ? Colors.red
                            : const Color(0xFFD4AF37),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isRtStreaming ? 'STREAMING ACTIVE' : 'TAP TO START',
                  style: TextStyle(
                    color: _isRtStreaming
                        ? Colors.red
                        : const Color(0xFFD4AF37),
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 32),
                OutlinedButton.icon(
                  onPressed: _isRtStreaming ? _verifyInputFeed : null,
                  icon: const Icon(Icons.bug_report, size: 18),
                  label: Text(
                    _isRtStreaming
                        ? 'DEBUG: VERIFY INPUT FEED'
                        : 'START STREAM TO VERIFY FEED',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD4AF37),
                    disabledForegroundColor: const Color(0xFF666666),
                    side: BorderSide(
                      color: _isRtStreaming
                          ? const Color(0xFFD4AF37)
                          : const Color(0xFF333333),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isRtStreaming && !_isMeasuringLatency
                      ? _measureRtLatency
                      : null,
                  icon: Icon(
                    _isMeasuringLatency ? Icons.graphic_eq : Icons.speed,
                    size: 18,
                  ),
                  label: Text(
                    _isMeasuringLatency
                        ? 'LISTENING FOR LOUD TEST SOUND'
                        : 'MEASURE LATENCY',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD4AF37),
                    disabledForegroundColor: const Color(0xFF666666),
                    side: BorderSide(
                      color: _isRtStreaming
                          ? const Color(0xFFD4AF37)
                          : const Color(0xFF333333),
                    ),
                  ),
                ),
                if (_lastLatencyMs != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Last latency: ${_lastLatencyMs!.toStringAsFixed(2)} ms',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed:
                      _isRtStreaming &&
                          !_isMeasuringLatency &&
                          !_isMeasuringChirpLatency
                      ? _measureChirpRtLatency
                      : null,
                  icon: Icon(
                    _isMeasuringChirpLatency ? Icons.graphic_eq : Icons.radar,
                    size: 18,
                  ),
                  label: Text(
                    _isMeasuringChirpLatency
                        ? 'MATCHING CHIRP SIGNAL'
                        : 'MEASURE CHIRP LATENCY',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD4AF37),
                    disabledForegroundColor: const Color(0xFF666666),
                    side: BorderSide(
                      color: _isRtStreaming
                          ? const Color(0xFFD4AF37)
                          : const Color(0xFF333333),
                    ),
                  ),
                ),
                if (_lastChirpLatencyMs != null ||
                    _lastChirpInputScore != null ||
                    _lastChirpOutputScore != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _lastChirpLatencyMs == null
                        ? 'Chirp match: input ${(_lastChirpInputScore ?? 0).toStringAsFixed(2)}, output ${(_lastChirpOutputScore ?? 0).toStringAsFixed(2)}'
                        : 'Chirp latency: ${_lastChirpLatencyMs!.toStringAsFixed(2)} ms  |  match ${(_lastChirpInputScore ?? 0).toStringAsFixed(2)} / ${(_lastChirpOutputScore ?? 0).toStringAsFixed(2)}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Sliders
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'HEARING LOSS PROFILE (GAIN)',
                  style: TextStyle(
                    color: Color(0xFF666666),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "0 dB (Normal)",
                      style: TextStyle(color: Color(0xFF555555), fontSize: 12),
                    ),
                    Text(
                      "120 dB (Profound)",
                      style: TextStyle(color: Color(0xFF555555), fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (int i = 0; i < 6; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 76,
                          child: Text(
                            _rtBandLabels[i],
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderThemeData(
                              activeTrackColor: const Color(0xFFD4AF37),
                              inactiveTrackColor: const Color(0xFF333333),
                              thumbColor: const Color(0xFFD4AF37),
                              overlayColor: const Color(
                                0xFFD4AF37,
                              ).withValues(alpha: 0.2),
                              trackHeight: 4,
                            ),
                            child: Slider(
                              value: _rtLosses[i],
                              min: -100.0,
                              max: 120.0,
                              divisions:
                                  22, // 120 - (-100) = 220, 220/10 = 22 divisions
                              onChanged: (val) => _onRtLossChanged(i, val),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 40,
                          child: Text(
                            '${_rtLosses[i].toInt()}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: Color(0xFFD4AF37),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openRecordToolsPage,
                icon: const Icon(Icons.mic_none_outlined, size: 18),
                label: const Text('OPEN RECORDING TOOLS'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFD4AF37),
                  side: const BorderSide(color: Color(0xFFD4AF37)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1C),
        elevation: 0,
        leading: _showRecordTools
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _showRecordTools = false),
              )
            : null,
        title: Text(
          _showRecordTools ? 'RECORDING TOOLS' : 'AMPLIFICATION',
          style: const TextStyle(
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: _showRecordTools ? _buildRecordTab() : _buildRealTimeTab(),
      ),
    );
  }
}
