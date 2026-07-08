import 'package:flutter/material.dart';

import '../amplification_status.dart';
import '../audio_generator.dart';
import '../models/profile.dart';
import 'screen_test.dart';

class HomeScreen extends StatefulWidget {
  final Profile profile;
  final VoidCallback onOpenTools;
  final VoidCallback onOpenAmplification;

  const HomeScreen({
    super.key,
    required this.profile,
    required this.onOpenTools,
    required this.onOpenAmplification,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioGenerator _audioGenerator = AudioGenerator();

  @override
  void dispose() {
    _audioGenerator.stopTone();
    super.dispose();
  }

  void _showTestModeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'SELECT TEST MODE',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: Colors.white54,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              _TestModeCard(
                title: 'STANDARD TEST',
                subtitle:
                    'Requires 3 consecutive detections to confirm each threshold',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ScreenTest(profile: widget.profile, requiredHits: 3),
                    ),
                  ).then((_) => setState(() {}));
                },
              ),
              const SizedBox(height: 12),
              _TestModeCard(
                title: 'ADVANCED TEST',
                subtitle:
                    'Requires 2 consecutive detections to confirm each threshold',
                isAdvanced: true,
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ScreenTest(profile: widget.profile, requiredHits: 2),
                    ),
                  ).then((_) => setState(() {}));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSoundCheckDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'CHECK YOUR EARBUDS',
          style: TextStyle(letterSpacing: 1),
        ),
        content: const Text(
          'Make sure you can hear the sound in the correct ear.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            child: const Text('CHECK LEFT EAR'),
            onPressed: () => _audioGenerator.playTone(
              frequency: 1000,
              amplitude: 40,
              channel: 'left',
              duration: 1000,
            ),
          ),
          TextButton(
            child: const Text('CHECK RIGHT EAR'),
            onPressed: () => _audioGenerator.playTone(
              frequency: 1000,
              amplitude: 40,
              channel: 'right',
              duration: 1000,
            ),
          ),
          TextButton(
            child: const Text('DONE'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'HELLO, ${widget.profile.name.toUpperCase()}',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Your hearing tools are ready.',
                style: TextStyle(color: Color(0xFF888888), fontSize: 14),
              ),
              const SizedBox(height: 28),
              _buildAmplificationPanel(),
              const SizedBox(height: 20),
              _buildToolsButton(),
              const SizedBox(height: 20),
              _buildTestActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAmplificationPanel() {
    return ValueListenableBuilder<AmplificationStatus>(
      valueListenable: amplificationStatusNotifier,
      builder: (context, status, _) {
        return Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1C),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFF2A2A2A)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: status.modeColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.hearing, color: status.modeColor),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AMPLIFICATION',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          status.isStreaming
                              ? 'Live audio is active'
                              : 'Start real-time amplification',
                          style: const TextStyle(
                            color: Color(0xFF8F8F8F),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF252525),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: status.modeColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${status.modeLabel} mode',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      status.isEnvironmentDetectionEnabled ? 'AUTO' : 'MANUAL',
                      style: TextStyle(
                        color: status.isEnvironmentDetectionEnabled
                            ? const Color(0xFFD4AF37)
                            : const Color(0xFF777777),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
              if (status.detectedEnvironment.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Detected ${status.detectedEnvironment} '
                  '(${(status.confidence * 100).toStringAsFixed(0)}%)',
                  style: const TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 22),
              ElevatedButton.icon(
                onPressed: widget.onOpenAmplification,
                icon: Icon(
                  status.isStreaming ? Icons.tune : Icons.power_settings_new,
                ),
                label: Text(
                  status.isStreaming
                      ? 'MANAGE AMPLIFICATION'
                      : 'START AMPLIFICATION',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.onOpenAmplification,
                icon: const Icon(Icons.radar),
                label: Text(
                  status.isEnvironmentDetectionEnabled
                      ? 'LIVE ENV DETECTION ENABLED'
                      : 'ENABLE LIVE ENV DETECTION',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: status.isEnvironmentDetectionEnabled
                      ? const Color(0xFFD4AF37)
                      : Colors.white,
                  side: BorderSide(
                    color: status.isEnvironmentDetectionEnabled
                        ? const Color(0xFFD4AF37)
                        : const Color(0xFF3A3A3A),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildToolsButton() {
    return OutlinedButton.icon(
      onPressed: widget.onOpenTools,
      icon: const Icon(Icons.build),
      label: const Text('TOOLS'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Color(0xFF3A3A3A)),
        padding: const EdgeInsets.symmetric(vertical: 18),
      ),
    );
  }

  Widget _buildTestActions() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF242424)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'HEARING TEST',
            style: TextStyle(
              color: Color(0xFFA0A0A0),
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: _showTestModeSheet,
            child: Text(
              widget.profile.testResults.isEmpty
                  ? 'START TEST'
                  : 'TRY ANOTHER TEST',
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _showSoundCheckDialog,
            child: const Text('CHECK EARBUDS'),
          ),
        ],
      ),
    );
  }
}

class _TestModeCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isAdvanced;

  const _TestModeCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isAdvanced = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = isAdvanced ? const Color(0xFFD4AF37) : Colors.white70;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          border: Border.all(color: accent.withValues(alpha: 0.4), width: 1.5),
          borderRadius: BorderRadius.circular(12),
          color: isAdvanced
              ? const Color(0xFFD4AF37).withValues(alpha: 0.07)
              : Colors.white.withValues(alpha: 0.04),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: accent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white54,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: accent.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}
