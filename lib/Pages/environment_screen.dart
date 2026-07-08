import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../audio_engine_ffi.dart';
import '../services/environment_detector.dart';

class EnvironmentScreen extends StatefulWidget {
  const EnvironmentScreen({super.key});

  @override
  State<EnvironmentScreen> createState() => _EnvironmentScreenState();
}

class _EnvironmentScreenState extends State<EnvironmentScreen>
    with TickerProviderStateMixin {
  // ---- Service ----
  final AudioEngineFFI _audioEngine = AudioEngineFFI();
  final EnvironmentDetectorService _detector = EnvironmentDetectorService();
  StreamSubscription<EnvironmentResult>? _resultSub;
  EnvironmentResult _latest = EnvironmentResult.initializing;
  bool _isDetecting = false;

  // ---- Settings (mirrored locally so sliders update immediately) ----
  double _silenceThreshold = 0.025;
  double _hopSeconds = 1.0;
  bool _useVoteSmoothing = true;

  // ---- Pulse animation ----
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;
  String _lastAnimatedMode = '';

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _resultSub?.cancel();
    _detector.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Toggle detection on/off
  // ---------------------------------------------------------------------------

  Future<void> _toggle() async {
    if (_isDetecting) {
      await _detector.stop();
      await _resultSub?.cancel();
      _resultSub = null;
      if (mounted) {
        setState(() {
          _isDetecting = false;
          _latest = EnvironmentResult.initializing;
          _lastAnimatedMode = '';
        });
      }
      return;
    }

    if (!_audioEngine.isPlaying()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Start real-time amplification before environment detection.',
            ),
            backgroundColor: Color(0xFF1C1C1C),
          ),
        );
      }
      return;
    }

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Microphone permission is required for environment detection.',
            ),
            backgroundColor: Color(0xFF1C1C1C),
          ),
        );
      }
      return;
    }

    // Push current settings to detector before starting.
    _syncSettingsToDetector();

    _resultSub = _detector.results.listen((result) {
      if (!mounted) return;
      setState(() {
        _latest = result;
      });

      final bool isDefined =
          result.mode == 'Transportation' || result.mode == 'Conversation';
      if (isDefined && result.mode != _lastAnimatedMode) {
        _lastAnimatedMode = result.mode;
        _pulseCtrl.forward(from: 0.0).then((_) {
          if (mounted) _pulseCtrl.reverse();
        });
      }
    });

    await _detector.start();

    if (mounted) {
      setState(() {
        _isDetecting = true;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Settings helpers
  // ---------------------------------------------------------------------------

  void _syncSettingsToDetector() {
    _detector.silenceThreshold = _silenceThreshold;
    _detector.hopSeconds = _hopSeconds;
    _detector.useVoteSmoothing = _useVoteSmoothing;
  }

  void _setThresholdFromRms() {
    final double rms = _latest.rms;
    if (rms <= 0.0) return;
    setState(() {
      // Round to 4 decimal places for a clean display.
      _silenceThreshold = double.parse(rms.toStringAsFixed(4));
    });
    _detector.silenceThreshold = _silenceThreshold;
  }

  // ---------------------------------------------------------------------------
  // UI helpers
  // ---------------------------------------------------------------------------

  IconData _iconForMode(String mode) {
    switch (mode) {
      case 'Transportation':
        return Icons.commute;
      case 'Conversation':
        return Icons.record_voice_over;
      case 'Silence':
        return Icons.volume_off_outlined;
      case 'Initializing':
        return Icons.hourglass_empty_outlined;
      default:
        return Icons.blur_on;
    }
  }

  Color _colorForMode(String mode) {
    switch (mode) {
      case 'Transportation':
        return const Color(0xFF4FC3F7);
      case 'Conversation':
        return const Color(0xFF81C784);
      case 'Silence':
        return const Color(0xFF666666);
      case 'Initializing':
        return const Color(0xFF666666);
      default:
        return const Color(0xFFD4AF37);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final Color modeColor = _colorForMode(_latest.mode);

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1C),
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'ENVIRONMENT DETECTION',
          style: TextStyle(
            color: Colors.white,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Mode card with pulse border ----
              AnimatedBuilder(
                animation: _pulseAnim,
                builder: (context, child) {
                  final double glow = _pulseAnim.value;
                  return Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1C),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: modeColor.withValues(alpha: 0.3 + glow * 0.7),
                        width: 1.5 + glow * 2.0,
                      ),
                      boxShadow: glow > 0.0
                          ? [
                              BoxShadow(
                                color: modeColor.withValues(alpha: glow * 0.35),
                                blurRadius: 18 * glow,
                                spreadRadius: 2 * glow,
                              ),
                            ]
                          : null,
                    ),
                    child: child,
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: modeColor.withValues(alpha: 0.12),
                          border: Border.all(
                            color: modeColor.withValues(alpha: 0.4),
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          _iconForMode(_latest.mode),
                          size: 38,
                          color: modeColor,
                        ),
                      ),
                      const SizedBox(height: 20),

                      Text(
                        _latest.mode.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: modeColor,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.5,
                        ),
                      ),
                      const SizedBox(height: 28),

                      _buildMetricRow(
                        label: 'CONFIDENCE',
                        trailing: Text(
                          '${(_latest.confidence * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: modeColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _latest.confidence,
                            minHeight: 8,
                            backgroundColor: const Color(0xFF2A2A2A),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              modeColor,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Stats row: P(conv) + RMS with "Set as threshold" button
                      Row(
                        children: [
                          Expanded(
                            child: _buildStatCard(
                              label: 'P(CONV)',
                              value: _latest.rawProb.toStringAsFixed(3),
                              color: const Color(0xFF81C784),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: _buildRmsCard()),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ---- Detection Settings card ----
              _buildSettingsCard(),

              const SizedBox(height: 32),

              // ---- Power button ----
              Center(
                child: GestureDetector(
                  onTap: _toggle,
                  child: Container(
                    height: 96,
                    width: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isDetecting
                          ? Colors.red.withValues(alpha: 0.1)
                          : const Color(0xFFD4AF37).withValues(alpha: 0.1),
                      border: Border.all(
                        color: _isDetecting
                            ? Colors.red
                            : const Color(0xFFD4AF37),
                        width: 3,
                      ),
                      boxShadow: _isDetecting
                          ? [
                              BoxShadow(
                                color: Colors.red.withValues(alpha: 0.3),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ]
                          : [],
                    ),
                    child: Center(
                      child: Icon(
                        Icons.power_settings_new,
                        size: 44,
                        color: _isDetecting
                            ? Colors.red
                            : const Color(0xFFD4AF37),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              Center(
                child: Text(
                  _isDetecting ? 'DETECTING...' : 'TAP TO START',
                  style: TextStyle(
                    color: _isDetecting ? Colors.red : const Color(0xFFD4AF37),
                    letterSpacing: 1.8,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Settings card
  // ---------------------------------------------------------------------------

  Widget _buildSettingsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'DETECTION SETTINGS',
            style: TextStyle(
              color: Color(0xFF666666),
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),

          // Vote smoothing toggle
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'VOTE SMOOTHING',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _useVoteSmoothing
                        ? 'Last 5 predictions averaged'
                        : 'Raw single-window output',
                    style: const TextStyle(
                      color: Color(0xFF666666),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              Switch(
                value: _useVoteSmoothing,
                onChanged: (v) {
                  setState(() => _useVoteSmoothing = v);
                  _detector.useVoteSmoothing = v;
                },
                activeThumbColor: const Color(0xFFD4AF37),
                inactiveThumbColor: const Color(0xFF444444),
                inactiveTrackColor: const Color(0xFF2A2A2A),
              ),
            ],
          ),

          const SizedBox(height: 20),
          const Divider(color: Color(0xFF2A2A2A), height: 1),
          const SizedBox(height: 20),

          // Silence threshold slider
          _buildSliderRow(
            label: 'SILENCE THRESHOLD',
            valueLabel: _silenceThreshold.toStringAsFixed(4),
            value: _silenceThreshold,
            min: 0.001,
            max: 0.150,
            onChanged: (v) {
              setState(() => _silenceThreshold = v);
              _detector.silenceThreshold = v;
            },
          ),

          const SizedBox(height: 20),
          const Divider(color: Color(0xFF2A2A2A), height: 1),
          const SizedBox(height: 20),

          // Hop size slider
          _buildSliderRow(
            label: 'HOP SIZE',
            valueLabel: '${_hopSeconds.toStringAsFixed(1)} s',
            value: _hopSeconds,
            min: 0.5,
            max: 4.0,
            divisions: 7, // 0.5 s steps
            onChanged: (v) {
              setState(() => _hopSeconds = v);
              _detector.hopSeconds = v;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF161616),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              child: Text(
                valueLabel,
                style: const TextStyle(
                  color: Color(0xFFD4AF37),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFFD4AF37),
            inactiveTrackColor: const Color(0xFF2A2A2A),
            thumbColor: const Color(0xFFD4AF37),
            overlayColor: const Color(0xFFD4AF37).withValues(alpha: 0.15),
            trackHeight: 3.0,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // RMS stat card with "Set as threshold" button
  // ---------------------------------------------------------------------------

  Widget _buildRmsCard() {
    final double rms = _latest.rms;
    final bool canSet = rms > 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'RMS',
            style: TextStyle(
              color: Color(0xFF666666),
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            rms.toStringAsFixed(4),
            style: const TextStyle(
              color: Color(0xFF4FC3F7),
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: canSet ? _setThresholdFromRms : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.arrow_upward,
                  size: 11,
                  color: canSet
                      ? const Color(0xFFD4AF37)
                      : const Color(0xFF444444),
                ),
                const SizedBox(width: 4),
                Text(
                  'SET AS THRESHOLD',
                  style: TextStyle(
                    color: canSet
                        ? const Color(0xFFD4AF37)
                        : const Color(0xFF444444),
                    fontSize: 9,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Metric row
  // ---------------------------------------------------------------------------

  Widget _buildMetricRow({
    required String label,
    required Widget child,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF666666),
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Small stat card
  // ---------------------------------------------------------------------------

  Widget _buildStatCard({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF666666),
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
