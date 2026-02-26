import 'dart:async';
import 'package:cleartone/Pages/results_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/profile.dart';
import '../models/hearing_test_result.dart';
import '../audio_generator.dart';
import '../path_finder.dart' as pathf;
import '../profile_storage.dart';

class ScreenTest extends StatefulWidget {
  final Profile profile;

  const ScreenTest({required this.profile, super.key});

  @override
  State<ScreenTest> createState() => _ScreenTestState();
}

class _ScreenTestState extends State<ScreenTest> {
  final AudioGenerator _audioGenerator = AudioGenerator();
  final ProfileStorage _profileStorage = ProfileStorage();
  String? _whiteNoisePath;

  // Test state
  String _testStatus = "";
  Timer? _countdownTimer;
  Timer? _responseTimer;
  int _countdown = 3;
  String? currentTestEar;

  // Hughson-Westlake state
  final List<int> _frequencies = [1000, 2000, 4000, 8000, 500, 250];
  int _currentFrequencyIndex = 0;
  double _currentAmplitude = 40.0;
  bool _isAscending = false;
  int _reversals = 0;
  int _lastHeardAmplitude = 0;
  bool _reversalCountingStarted = false;

  final Map<int, int> _leftEarResults = {};
  final Map<int, int> _rightEarResults = {};
  String _currentEar = "left";

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _responseTimer?.cancel();
    _audioGenerator.stopFile();
    _audioGenerator.stopTone();
    super.dispose();
  }

  void _initialize() async {
    // Get the path to the white noise file
    _whiteNoisePath = await pathf.getFilePathFromAsset(
      'assets/audio/white_noice.wav',
    );
    if (!mounted) return;
    _startCountdown();
  }

  void _startCountdown() {
    setState(() {
      _countdown = 3;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 1) {
        setState(() => _countdown--);
      } else {
        timer.cancel();
        _startTest();
      }
    });
  }

  void _startTest() {
    _countdown = 0;
    _currentEar = "left";
    _resetFrequencyVariables();
    _playNextTone();
  }

  void _playNextTone() {
    _responseTimer?.cancel();
    setState(() {
      _testStatus = "TESTING ${_currentEar.toUpperCase()} EAR";
    });

    String nonTestEar = _currentEar == "left" ? "right" : "left";

    if (_currentEar != currentTestEar) {
      currentTestEar = _currentEar;
      if (_whiteNoisePath != null) {
        _audioGenerator.playFile(
          filePath: _whiteNoisePath!,
          channel: nonTestEar,
          amplitude: 30.0, // Masking amplitude
        );
      }
    }

    _audioGenerator.playTone(
      frequency: _frequencies[_currentFrequencyIndex].toDouble(),
      amplitude: _currentAmplitude,
      channel: _currentEar,
      duration: 4000, // 4-second tone
    );

    // Wait 4 seconds for user input. If none, register as 'no' (not heard).
    _responseTimer = Timer(const Duration(milliseconds: 4000), () {
      if (mounted) {
        _userHeardTone(false);
      }
    });
  }

  void _userHeardTone(bool heard) {
    if (!_reversalCountingStarted) {
      if (heard) {
        _lastHeardAmplitude = _currentAmplitude.toInt();
        _currentAmplitude -= 10;
        _playNextTone();
      } else {
        // First 'No', start reversal process
        _reversalCountingStarted = true;
        _isAscending = true; // Start ascending
        _currentAmplitude += 5;
        _playNextTone();
      }
      return;
    }

    if (heard) {
      _lastHeardAmplitude = _currentAmplitude.toInt();
      if (_isAscending) {
        // We were going up and they heard it
        _reversals++;
        _isAscending = false; // Reverse direction to descending
        _currentAmplitude -= 10;
      } else {
        // We were going down and they still heard it
        _currentAmplitude -= 10;
      }
    } else {
      // Not heard
      if (!_isAscending) {
        // We were going down and they missed it
        _reversals++;
        _isAscending = true; // Reverse direction to ascending
        _currentAmplitude += 5;
      } else {
        // We were going up and they still can't hear it
        _currentAmplitude += 5;
      }
    }

    if (_reversals >= 3) {
      // Using 3 reversals
      _recordResultAndMoveOn();
    } else {
      _playNextTone();
    }
  }

  void _recordResultAndMoveOn() {
    final threshold = _lastHeardAmplitude;
    if (_currentEar == "left") {
      _leftEarResults[_frequencies[_currentFrequencyIndex]] = threshold;
    } else {
      _rightEarResults[_frequencies[_currentFrequencyIndex]] = threshold;
    }

    // Move to next frequency or ear
    if (_currentFrequencyIndex < _frequencies.length - 1) {
      _currentFrequencyIndex++;
      _resetFrequencyVariables();
      _playNextTone();
    } else if (_currentEar == "left") {
      _currentEar = "right";
      _currentFrequencyIndex = 0;
      _resetFrequencyVariables();
      _playNextTone();
    } else {
      // Test is complete
      _finishTest();
    }
  }

  void _resetFrequencyVariables() {
    _currentAmplitude = 40.0;
    _isAscending = false;
    _reversals = 0;
    _lastHeardAmplitude = 0;
    _reversalCountingStarted = false;
  }

  Future<void> _finishTest() async {
    _responseTimer?.cancel();
    final result = HearingTestResult(
      leftEarResults: _leftEarResults,
      rightEarResults: _rightEarResults,
    );

    widget.profile.testResults.add(result);
    if (widget.profile.testResults.length > 3) {
      widget.profile.testResults.removeAt(0); // Keep only the latest 3
    }

    await _profileStorage.saveProfile(widget.profile);

    _audioGenerator.stopFile();

    if (!mounted) return;

    setState(() {
      _testStatus = "Test Complete!";
    });

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ResultsScreen(profile: widget.profile),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("HI, ${widget.profile.name.toUpperCase()}")),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: _buildTestView(),
        ),
      ),
    );
  }

  Widget _buildTestView() {
    if (_countdown > 0) {
      return Text(
        "STARTING IN $_countdown...",
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          _testStatus,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: const Color(0xFFD4AF37),
            letterSpacing: 1,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        const Text(
          "TAP THE BUTTON IF YOU HEAR A TONE",
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 1.5,
            color: Colors.white70,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 64),
        GestureDetector(
          onTap: () {
            if (_responseTimer?.isActive ?? false) {
              _responseTimer?.cancel();
              HapticFeedback.lightImpact();
              _userHeardTone(true);
            }
          },
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF1C1C1C),
              border: Border.all(color: const Color(0xFFD4AF37), width: 4),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFD4AF37).withValues(alpha: 0.2),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: const Center(
              child: Text(
                "YES",
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
