import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio_engine_ffi.dart';
import '../services/evidence_collector.dart';

/// DSP evidence collection screen (docs/validation.md).
///
/// Lets a developer/researcher run the offline pure-tone / sweep /
/// mode-comparison DSP verification tests (no microphone needed -- they run
/// the real RealtimeProcessor pipeline against synthesized test signals),
/// and start/stop/export a live-microphone diagnostic capture. The output
/// is a timestamped `cleartone_evidence/session_.../` folder; pull it off
/// the device and run `tools/generate_dsp_evidence_plots.py` to generate
/// the report-ready plots and summary.
class EvidenceScreen extends StatefulWidget {
  final List<double> currentLoss6;
  final int currentMode;

  const EvidenceScreen({
    super.key,
    required this.currentLoss6,
    required this.currentMode,
  });

  @override
  State<EvidenceScreen> createState() => _EvidenceScreenState();
}

class _EvidenceScreenState extends State<EvidenceScreen> {
  final EvidenceCollector _collector = EvidenceCollector();
  final AudioEngineFFI _engine = AudioEngineFFI();

  SessionPaths? _session;
  bool _busy = false;
  bool _liveCapturing = false;
  int _selectedMode = 0;
  final List<String> _log = [];

  static const List<String> _modeLabels = ['Standard', 'Transit', 'Conversation'];

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.currentMode;
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() => _log.insert(0, message));
  }

  Future<void> _runBusy(String label, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    _addLog('Starting: $label');
    try {
      await action();
      _addLog('Done: $label');
    } catch (e) {
      _addLog('Failed: $label -- $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Creates the session directory tree AND writes its metadata in one step
  /// -- every codepath that starts a session (offline experiment buttons as
  /// well as the explicit "New session" button) must produce a session with
  /// metadata/dsp_config.json present, or the analysis script silently
  /// falls back to an all-zero gain profile.
  Future<SessionPaths> _createSessionWithMetadata() async {
    final paths = await _collector.createSession();
    setState(() => _session = paths);
    _addLog('Created session ${paths.sessionId}');
    _addLog('Path: ${paths.root}');
    await _collector.writeMetadata(
      paths,
      experimentType: EvidenceExperimentType.liveMicrophoneTest,
      mode: _selectedMode,
      loss6: widget.currentLoss6,
      modeLabel: _modeLabels[_selectedMode],
      testNotes:
          'Session created from the ClearTone Evidence screen. Digital DSP '
          'verification / implementation-level evidence -- not a clinical validation.',
    );
    _addLog('Wrote metadata (session_config.json, device_info.json, '
        'dsp_config.json, gain_profile.csv, mode_config.csv)');
    return paths;
  }

  Future<SessionPaths> _ensureSession() async {
    if (_session != null) return _session!;
    return _createSessionWithMetadata();
  }

  Future<void> _newSession() async {
    await _runBusy('New session', () async {
      await _createSessionWithMetadata();
    });
  }

  Future<void> _runPureTone() async {
    final paths = await _ensureSession();
    await _runBusy('Pure-tone battery (6 tones)', () async {
      await _collector.runPureToneBattery(
        paths,
        loss6: widget.currentLoss6,
        mode: _selectedMode,
      );
      _addLog('Wrote 12 pure-tone WAV files + band/limiter log rows '
          '(mode: ${_modeLabels[_selectedMode]})');
    });
  }

  Future<void> _runSweep() async {
    final paths = await _ensureSession();
    await _runBusy('Frequency sweep (20Hz-10kHz)', () async {
      await _collector.runSweepTest(
        paths,
        loss6: widget.currentLoss6,
        mode: _selectedMode,
      );
      _addLog('Wrote sweep WAV pair + band/limiter log rows');
    });
  }

  Future<void> _runModeComparison() async {
    final paths = await _ensureSession();
    await _runBusy('Mode comparison (Standard/Transit/Conversation)', () async {
      await _collector.runModeComparison(paths, loss6: widget.currentLoss6);
      _addLog('Wrote mode_test_raw_input.wav + 3 processed WAV files');
    });
  }

  Future<void> _startLiveCapture() async {
    if (!_engine.isPlaying()) {
      _addLog('Start real-time amplification (Amplify tab) before live capture.');
      return;
    }
    final paths = await _ensureSession();
    await _runBusy('Start live capture', () async {
      await _collector.startLiveCapture(paths, mode: _selectedMode);
      setState(() => _liveCapturing = true);
      _addLog('Live capture armed -- speak into the microphone now.');
    });
  }

  Future<void> _stopLiveCapture() async {
    final paths = _session;
    if (paths == null) return;
    await _runBusy('Stop & flush live capture', () async {
      final written = await _collector.stopAndFlushLiveCapture(paths);
      setState(() => _liveCapturing = false);
      _addLog('Flushed $written file(s) to logs/ and audio/');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1C),
        elevation: 0,
        title: const Text(
          'DSP EVIDENCE',
          style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.w600, fontSize: 16),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _disclaimerCard(),
            const SizedBox(height: 16),
            _sessionCard(),
            const SizedBox(height: 16),
            _modeSelector(),
            const SizedBox(height: 16),
            _offlineExperimentsCard(),
            const SizedBox(height: 16),
            _liveCaptureCard(),
            const SizedBox(height: 16),
            _logCard(),
          ],
        ),
      ),
    );
  }

  Widget _disclaimerCard() {
    return _card(
      child: const Text(
        'These tools produce digital DSP verification and implementation-level '
        'evidence for a final year project report/paper. Results are a '
        'preliminary engineering result observed under the tested device '
        'configuration -- not a clinical validation.',
        style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 12, height: 1.4),
      ),
    );
  }

  Widget _sessionCard() {
    final session = _session;
    return _card(
      title: 'Session',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (session == null)
            const Text('No session yet.', style: TextStyle(color: Color(0xFF888888)))
          else ...[
            SelectableText(
              session.sessionId,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            SelectableText(
              session.root,
              style: const TextStyle(color: Color(0xFF888888), fontSize: 11),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: session.root));
                      _addLog('Copied session path to clipboard.');
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy path'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _newSession,
              icon: const Icon(Icons.add),
              label: const Text('New session'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD4AF37),
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeSelector() {
    return _card(
      title: 'DSP mode for offline tests',
      child: SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 0, label: Text('Standard')),
          ButtonSegment(value: 1, label: Text('Transit')),
          ButtonSegment(value: 2, label: Text('Conversation')),
        ],
        selected: {_selectedMode},
        onSelectionChanged: _busy
            ? null
            : (s) => setState(() => _selectedMode = s.first),
      ),
    );
  }

  Widget _offlineExperimentsCard() {
    return _card(
      title: 'Offline experiments (no microphone needed)',
      subtitle:
          'Runs synthesized test signals through the exact RealtimeProcessor '
          'the live engine uses.',
      child: Column(
        children: [
          _actionButton('Run pure-tone battery (250Hz-8kHz)', Icons.graphic_eq, _runPureTone),
          const SizedBox(height: 8),
          _actionButton('Run frequency sweep (20Hz-10kHz)', Icons.show_chart, _runSweep),
          const SizedBox(height: 8),
          _actionButton(
            'Run mode comparison (Standard/Transit/Conversation)',
            Icons.compare_arrows,
            _runModeComparison,
          ),
        ],
      ),
    );
  }

  Widget _liveCaptureCard() {
    return _card(
      title: 'Live microphone capture',
      subtitle: 'Requires real-time amplification already running (Amplify tab).',
      child: _liveCapturing
          ? _actionButton('Stop && flush live capture', Icons.stop_circle, _stopLiveCapture)
          : _actionButton('Start live capture', Icons.mic, _startLiveCapture),
    );
  }

  Widget _actionButton(String label, IconData icon, Future<void> Function() onPressed) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _busy ? null : onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, textAlign: TextAlign.left),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          alignment: Alignment.centerLeft,
          foregroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFF2A2A2A)),
        ),
      ),
    );
  }

  Widget _logCard() {
    return _card(
      title: 'Activity log',
      child: _log.isEmpty
          ? const Text('No activity yet.', style: TextStyle(color: Color(0xFF888888)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _log
                  .take(30)
                  .map(
                    (line) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        line,
                        style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 12),
                      ),
                    ),
                  )
                  .toList(),
            ),
    );
  }

  Widget _card({String? title, String? subtitle, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: Color(0xFF888888), fontSize: 11)),
          ],
          if (title != null || subtitle != null) const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
