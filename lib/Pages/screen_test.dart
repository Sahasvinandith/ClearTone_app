import 'dart:async';
import 'package:cleartone/Pages/results_screen.dart';
import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../models/hearing_test_result.dart';
import '../audio_generator.dart';
import '../path_finder.dart' as pathf;

class ScreenTest extends StatefulWidget {
  final Profile profile;

  const ScreenTest({required this.profile, super.key});

  @override
  State<ScreenTest> createState() => _ScreenTestState();
}

class _ScreenTestState extends State<ScreenTest> {
  final AudioGenerator _audioGenerator = AudioGenerator();
  String? _whiteNoisePath;

  // Test state
  bool _isTesting = false;
  String _testStatus = "";
  Timer? _countdownTimer;
  int _countdown = 3;

  // Hughson-Westlake state
  final List<int> _frequencies = [1000, 2000, 4000, 8000, 500, 250];
  int _currentFrequencyIndex = 0;
  double _currentAmplitude = 40.0;
  bool _isAscending = false;
  int _reversals = 0;
  int _lastHeardAmplitude = 0;

  final Map<int, int> _leftEarResults = {};
  final Map<int, int> _rightEarResults = {};
  String _currentEar = "left";

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  void _initialize() async {
    // Get the path to the white noise file
    _whiteNoisePath = await pathf.getFilePathFromAsset('assets/audio/white_noice.wav');
    setState(() {
      _testStatus = "Welcome, ${widget.profile.name}. Ready to start?";
    });
  }

  void _showSoundCheckDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Check Your Earbuds"),
        content: const Text("Make sure you can hear the sound in the correct ear."),
        actions: [
          TextButton(
            child: const Text("Check Left Ear"),
            onPressed: () => _audioGenerator.playTone(
                frequency: 1000, amplitude: 40, channel: 'left', duration: 1000),
          ),
          TextButton(
            child: const Text("Check Right Ear"),
            onPressed: () => _audioGenerator.playTone(
                frequency: 1000, amplitude: 40, channel: 'right', duration: 1000),
          ),
          TextButton(
            child: const Text("Done"),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  void _startCountdown() {
    setState(() {
      _isTesting = true;
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
    _countdown = 0; // <-- THE FIX IS HERE
    _currentEar = "left";
    _resetFrequencyVariables();
    _playNextTone();
  }

  void _playNextTone() {
    setState(() {
      _testStatus = "Playing at ${_frequencies[_currentFrequencyIndex]} Hz...";
    });

    String nonTestEar = _currentEar == "left" ? "right" : "left";
    if (_whiteNoisePath != null) {
      _audioGenerator.playFile(
          filePath: _whiteNoisePath!,
          channel: nonTestEar,
          amplitude: 30.0 // Masking amplitude
          );
    }

    _audioGenerator.playTone(
      frequency: _frequencies[_currentFrequencyIndex].toDouble(),
      amplitude: _currentAmplitude,
      channel: _currentEar,
      duration: 3000, // 3-second tone
    );
  }

  void _userHeardTone(bool heard) {
    if (heard) {
      _reversals++;
      _lastHeardAmplitude = _currentAmplitude.toInt();
      _currentAmplitude -= 10; // Decrease by 10 dB
      _isAscending = false;
    } else {
      if (!_isAscending) {
        _reversals++;
        _isAscending = true;
      }
      _currentAmplitude += 5; // Increase by 5 dB
    }

    if (_reversals >= 5) { // Simplified threshold detection
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
  }

  void _finishTest() {
    final result = HearingTestResult(
        leftEarResults: _leftEarResults,
        rightEarResults: _rightEarResults);
    widget.profile.testResult = result;

    setState(() {
      _isTesting = false;
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
      appBar: AppBar(title: Text("Hi, ${widget.profile.name}")),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: _isTesting
              ? _buildTestView()
              : _buildPreTestView(),
        ),
      ),
    );
  }

  Widget _buildPreTestView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_testStatus, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center,),
        const SizedBox(height: 40),
        ElevatedButton(onPressed: _showSoundCheckDialog, child: const Text("Check Earbuds")),
        const SizedBox(height: 20),
        ElevatedButton(onPressed: _startCountdown, child: const Text("Start Test")),
      ],
    );
  }

  Widget _buildTestView() {
    if (_countdown > 0) {
      return Text("Starting in $_countdown...", style: Theme.of(context).textTheme.headlineMedium);
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_testStatus, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center,),
        const SizedBox(height: 50),
        const Text("Did you hear the sound?", style: TextStyle(fontSize: 20)),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton(onPressed: () => _userHeardTone(true), child: const Text("Yes")),
            ElevatedButton(onPressed: () => _userHeardTone(false), child: const Text("No")),
          ],
        ),
      ],
    );
  }
}
