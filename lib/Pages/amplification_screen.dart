import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'dart:io';
import '../models/profile.dart';

class AmplificationScreen extends StatefulWidget {
  final Profile profile;

  const AmplificationScreen({super.key, required this.profile});

  @override
  State<AmplificationScreen> createState() => _AmplificationScreenState();
}

class _AmplificationScreenState extends State<AmplificationScreen> {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;
  bool _hasPermission = false;
  List<FileSystemEntity> _recordings = [];
  String? _currentlyPlayingPath;
  bool _isPlaying = false;

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
        return filename.startsWith('amplification_${widget.profile.name}_') &&
            filename.endsWith('.m4a');
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
          '${directory.path}/amplification_${widget.profile.name}_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
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
                              ? Colors.red.withOpacity(0.2)
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

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1C),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isCurrentlyPlaying
                              ? const Color(0xFFD4AF37)
                              : const Color(0xFF2A2A2A),
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: isCurrentlyPlaying
                              ? const Color(0xFFD4AF37).withOpacity(0.2)
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
                        title: Text(
                          'Recording ${index + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            _formatDateTime(stat.modified),
                            style: const TextStyle(
                              color: Color(0xFF666666),
                              fontSize: 12,
                            ),
                          ),
                        ),
                        onTap: () => _togglePlayback(file.path),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
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
                                      style: TextStyle(color: Colors.redAccent),
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
