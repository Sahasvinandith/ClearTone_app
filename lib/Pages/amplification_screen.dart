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

class AmplificationScreen extends StatefulWidget {
  final Profile profile;

  const AmplificationScreen({super.key, required this.profile});

  @override
  State<AmplificationScreen> createState() => _AmplificationScreenState();
}

class _AmplificationScreenState extends State<AmplificationScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // --- Record Mode State ---
  AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioEngineFFI _audioEngine = AudioEngineFFI();
  bool _isRecording = false;
  bool _hasPermission = false;
  List<FileSystemEntity> _recordings = [];
  String? _currentlyPlayingPath;
  bool _isPlaying = false;
  bool _isProcessingAudioFile = false;

  // --- Real-time Mode State ---
  static const MethodChannel _audioChannel = MethodChannel(
    'com.cleartone/audio',
  );
  List<Map<String, dynamic>> _audioDevices = [];
  int? _selectedDeviceId;
  bool _isRtStreaming = false;
  bool _isCommunicationMode = true; // Default to VoiceCommunication
  Timer? _reconnectTimer;

  // Real-time sliders
  final List<int> _rtBands = [
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ]; // Display labels
  late List<double> _rtLosses;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
          }
        });
      }
    });

    _initRtGainFromProfile();
    _startReconnectTimer();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    if (_isRtStreaming) {
      _audioEngine.stopRtStream();
    }
    _tabController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _startReconnectTimer() {
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isRtStreaming) {
        bool actuallyPlaying = _audioEngine.isPlaying();
        if (!actuallyPlaying) {
          debugPrint("Audio engine stopped unexpectedly. Attempting restart...");
          
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
              await _audioChannel.invokeMethod('enableBluetoothSco', {'enable': true});
              await Future.delayed(const Duration(milliseconds: 500));
            } catch (e) {
              debugPrint("Error re-enabling Bluetooth SCO: $e");
            }
          }
          
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
      List<int> sortedFreqs = latestResult.leftEarResults.keys.toList()..sort();
      List<double> avgLoss = [];
      for (int freq in sortedFreqs) {
        double left = latestResult.leftEarResults[freq]?.toDouble() ?? 0.0;
        double right = latestResult.rightEarResults[freq]?.toDouble() ?? 0.0;
        avgLoss.add((left + right) / 2.0);
      }
      while (avgLoss.length < 6) avgLoss.add(0.0);
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

  void _toggleRtStream() async {
    if (_isRtStreaming) {
      _audioEngine.stopRtStream();
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
      });
    } else {
      if (_selectedDeviceId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a microphone first.')),
        );
        return;
      }

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
          (selectedDevice['type'] as int? ?? -1) == 7; // AudioDeviceInfo.TYPE_BLUETOOTH_SCO

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

      // 3. Start Oboe Stream
      int result = _audioEngine.startRtStream(_selectedDeviceId!);
      print("Result: $result");
      if (result == 0) {
        _audioEngine.updateRtParams(_rtLosses);
        setState(() {
          _isRtStreaming = true;
        });
      } else {
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

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final inputPath = '${directory.path}/input_verify_$timestamp.raw';
      final outputPath = '${directory.path}/output_verify_$timestamp.raw';

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Capturing 3 seconds of Input & Output...')),
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
                Text('Samples captured: $size', style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                const Text('INPUT (Mic):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                SelectableText(inputPath, style: const TextStyle(fontSize: 12, color: Color(0xFFD4AF37))),
                const SizedBox(height: 12),
                const Text('OUTPUT (Amplified):', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                SelectableText(outputPath, style: const TextStyle(fontSize: 12, color: Color(0xFFD4AF37))),
                const SizedBox(height: 16),
                const Text(
                  'Use "adb pull" to retrieve both files and compare them in Audacity.',
                  style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey, fontSize: 12),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Verification error: $e')),
      );
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
      print("Recording started.");
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

  Future<void> _deleteRecording(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        if (_currentlyPlayingPath == path) {
          await _audioPlayer.stop();
          if (mounted) {
            setState(() {
              _currentlyPlayingPath = null;
              _isPlaying = false;
            });
          }
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

  Future<void> _processAudioFile(String inputPath) async {
    if (_isProcessingAudioFile) return;

    setState(() {
      _isProcessingAudioFile = true;
    });

    try {
      if (widget.profile.testResults.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Profile needs at least one test result to process audio!',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final outPath = inputPath.replaceAll('.wav', '_processed.wav');
      final latestResult = widget.profile.testResults.last;

      List<int> sortedFreqs = latestResult.leftEarResults.keys.toList()..sort();
      List<double> avgLoss = [];
      for (int freq in sortedFreqs) {
        double left = latestResult.leftEarResults[freq]?.toDouble() ?? 0.0;
        double right = latestResult.rightEarResults[freq]?.toDouble() ?? 0.0;
        avgLoss.add((left + right) / 2.0);
      }

      while (avgLoss.length < 6) avgLoss.add(0.0);
      if (avgLoss.length > 6) avgLoss = avgLoss.sublist(0, 6);

      final result = _audioEngine.processAudio(
        inPath: inputPath,
        outPath: outPath,
        loss6: avgLoss,
      );

      if (result == 0) {
        _loadRecordings();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Audio processed successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        throw Exception('Audio engine returned error code: $result');
      }
    } catch (e) {
      debugPrint('Error processing audio: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error processing audio: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingAudioFile = false;
        });
      }
    }
  }

  // --- UI Builders ---

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
                final isCurrentlyPlaying = _currentlyPlayingPath == file.path;
                final filename = file.path.split('/').last;

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isCurrentlyPlaying
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
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: isCurrentlyPlaying
                              ? const Color(0xFFD4AF37).withValues(alpha: 0.2)
                              : const Color(0xFF282828),
                          child: Icon(
                            isCurrentlyPlaying && _isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: isCurrentlyPlaying
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
                        Wrap(
                          spacing: -8,
                          children: [
                            if (!filename.contains('_processed') &&
                                filename.endsWith('.wav'))
                              IconButton(
                                icon: _isProcessingAudioFile
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Color(0xFFD4AF37),
                                        ),
                                      )
                                    : const Icon(
                                        Icons.auto_fix_high,
                                        color: Color(0xFFD4AF37),
                                      ),
                                onPressed: _isProcessingAudioFile
                                    ? null
                                    : () => _processAudioFile(file.path),
                                tooltip: 'Process Audio',
                                constraints: const BoxConstraints(),
                                padding: const EdgeInsets.all(8),
                              ),
                            IconButton(
                              icon: Icon(
                                isCurrentlyPlaying && _isPlaying
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill,
                                color: const Color(0xFFD4AF37),
                                size: 28,
                              ),
                              onPressed: () => _togglePlayback(file.path),
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
                                        onPressed: () => Navigator.pop(context),
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
                            icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFFD4AF37)),
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            items: _audioDevices.map((device) {
                              return DropdownMenuItem<int>(
                                value: device['id'] as int,
                                child: Text(device['name'] as String),
                              );
                            }).toList(),
                            onChanged: _isRtStreaming ? null : (value) {
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
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                                  _isCommunicationMode ? 'Communication Mode' : 'Media Mode',
                                  style: const TextStyle(color: Colors.white, fontSize: 14),
                                ),
                                Text(
                                  _isCommunicationMode 
                                    ? 'Used for Bluetooth Headsets (SCO)' 
                                    : 'Better for Wired / Phone Speaker',
                                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                                ),
                              ],
                            ),
                            Switch(
                              value: _isCommunicationMode,
                              activeColor: const Color(0xFFD4AF37),
                              onChanged: _isRtStreaming ? null : (value) {
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
                  label: Text(_isRtStreaming
                      ? 'DEBUG: VERIFY INPUT FEED'
                      : 'START STREAM TO VERIFY FEED'),
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
                          width: 60,
                          child: Text(
                            '${_rtBands[i]} Hz',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold,
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
        title: const Text(
          'AMPLIFICATION',
          style: TextStyle(
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFFD4AF37),
          labelColor: const Color(0xFFD4AF37),
          unselectedLabelColor: const Color(0xFF666666),
          tabs: const [
            Tab(text: "RECORD"),
            Tab(text: "REAL-TIME"),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [_buildRecordTab(), _buildRealTimeTab()],
        ),
      ),
    );
  }
}
