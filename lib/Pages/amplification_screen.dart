import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:io';
import '../models/profile.dart';
import '../audio_engine_ffi.dart';

class AmplificationScreen extends StatefulWidget {
  final Profile profile;

  const AmplificationScreen({super.key, required this.profile});

  @override
  State<AmplificationScreen> createState() => _AmplificationScreenState();
}

class _AmplificationScreenState extends State<AmplificationScreen> {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioEngineFFI _audioEngine = AudioEngineFFI();
  bool _isRecording = false;
  bool _hasPermission = false;
  List<FileSystemEntity> _recordings = [];
  String? _currentlyPlayingPath;
  bool _isPlaying = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
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
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

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
        print("file name is " + filename.toString());
        return filename.startsWith('amplification_${widget.profile.name}_') &&
            filename.endsWith('.wav');
      }).toList();

      // Sort newest first
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

  Future<void> _processAudio(String inputPath) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
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

      // Generate output path by appending '_processed' before '.wav'
      final outPath = inputPath.replaceAll('.wav', '_processed.wav');

      // Get latest test result
      final latestResult = widget.profile.testResults.last;

      // Calculate avg loss between left and right ear for each band
      // Since the engine uses 6 bands and the test has 6 fixed frequencies
      // Assuming test frequencies: 250, 500, 1000, 2000, 4000, 8000
      List<int> sortedFreqs = latestResult.leftEarResults.keys.toList()..sort();
      List<double> avgLoss = [];
      for (int freq in sortedFreqs) {
        double left = latestResult.leftEarResults[freq]?.toDouble() ?? 0.0;
        double right = latestResult.rightEarResults[freq]?.toDouble() ?? 0.0;
        avgLoss.add((left + right) / 2.0);
      }

      while (avgLoss.length < 6) {
        avgLoss.add(0.0);
      }
      if (avgLoss.length > 6) avgLoss = avgLoss.sublist(0, 6);

      final result = _audioEngine.processAudio(
        inPath: inputPath,
        outPath: outPath,
        loss6: avgLoss,
      );

      if (result == 0) {
        _loadRecordings(); // Reload to show the new processed file
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
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111111),
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
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              // Top Section: Recording Controls
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
              // Bottom Section: Recorded List
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemBuilder: (context, index) {
                    final file = _recordings[index];
                    final stat = File(file.path).statSync();
                    final isCurrentlyPlaying =
                        _currentlyPlayingPath == file.path;
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
                                  ? const Color(
                                      0xFFD4AF37,
                                    ).withValues(alpha: 0.2)
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
                              spacing:
                                  -8, // Reduce horizontal spacing between buttons
                              children: [
                                if (!filename.contains('_processed') &&
                                    filename.endsWith('.wav'))
                                  IconButton(
                                    icon: _isProcessing
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
                                    onPressed: _isProcessing
                                        ? null
                                        : () => _processAudio(file.path),
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
                                        backgroundColor: const Color(
                                          0xFF1C1C1C,
                                        ),
                                        title: const Text('Delete Recording?'),
                                        content: const Text(
                                          'Are you sure you want to delete this recording?',
                                          style: TextStyle(
                                            color: Colors.white70,
                                          ),
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
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
