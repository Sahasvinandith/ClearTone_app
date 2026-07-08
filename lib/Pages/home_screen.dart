import 'package:flutter/material.dart';

import '../amplification_status.dart';
import '../models/profile.dart';

class HomeScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 640;
            final padding = compact ? 16.0 : 22.0;
            final gap = compact ? 10.0 : 16.0;

            return Padding(
              padding: EdgeInsets.fromLTRB(padding, padding, padding, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(name: profile.name, compact: compact),
                  SizedBox(height: gap),
                  _AmplificationTile(
                    compact: compact,
                    onOpenAmplification: onOpenAmplification,
                  ),
                  SizedBox(height: gap),
                  _ToolsTile(onTap: onOpenTools, compact: compact),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String name;
  final bool compact;

  const _Header({required this.name, required this.compact});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 52 : 68,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'HI, ${name.toUpperCase()}',
              maxLines: 1,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                fontSize: compact ? 22 : 26,
              ),
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 4),
            const Text(
              'Amplification controls are ready.',
              style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

class _AmplificationTile extends StatelessWidget {
  final bool compact;
  final VoidCallback onOpenAmplification;

  const _AmplificationTile({
    required this.compact,
    required this.onOpenAmplification,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AmplificationStatus>(
      valueListenable: amplificationStatusNotifier,
      builder: (context, status, _) {
        return Container(
          padding: EdgeInsets.all(compact ? 12 : 16),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1C),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: status.isStreaming
                  ? const Color(0xFFE65B5B)
                  : const Color(0xFF55D18A),
              width: 1.4,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tight = constraints.maxHeight < 360;
              final sectionGap = tight ? 6.0 : 10.0;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _AmplificationSummary(
                    status: status,
                    compact: tight,
                    onOpenAmplification: onOpenAmplification,
                  ),
                  SizedBox(height: sectionGap),
                  _PrimaryActions(status: status, compact: tight),
                  SizedBox(height: sectionGap),
                  _ModePicker(status: status, compact: tight),
                  SizedBox(height: sectionGap),
                  _DetectionReadout(status: status, compact: tight),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _AmplificationSummary extends StatelessWidget {
  final AmplificationStatus status;
  final bool compact;
  final VoidCallback onOpenAmplification;

  const _AmplificationSummary({
    required this.status,
    required this.compact,
    required this.onOpenAmplification,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: compact ? 40 : 50,
          height: compact ? 40 : 50,
          decoration: BoxDecoration(
            color: status.modeColor.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            status.isStreaming ? Icons.hearing : Icons.hearing_outlined,
            color: status.modeColor,
            size: compact ? 22 : 28,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AMPLIFICATION',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 13 : 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '${status.modeLabel} mode',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: status.modeColor,
                  fontSize: compact ? 12 : 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        _StatusPill(
          label: status.isStreaming ? 'ACTIVE' : 'READY',
          color: status.isStreaming
              ? const Color(0xFFE65B5B)
              : const Color(0xFF55D18A),
          compact: compact,
        ),
        const SizedBox(width: 8),
        _AdvancedControlsButton(
          compact: compact,
          onPressed: onOpenAmplification,
        ),
      ],
    );
  }
}

class _AdvancedControlsButton extends StatelessWidget {
  final bool compact;
  final VoidCallback onPressed;

  const _AdvancedControlsButton({
    required this.compact,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Advanced controls',
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: compact ? 36 : 40,
          height: compact ? 34 : 38,
          decoration: BoxDecoration(
            color: const Color(0xFF242424),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF3A3A3A)),
          ),
          child: Icon(
            Icons.tune,
            color: const Color(0xFFD4AF37),
            size: compact ? 18 : 20,
          ),
        ),
      ),
    );
  }
}

class _PrimaryActions extends StatelessWidget {
  final AmplificationStatus status;
  final bool compact;

  const _PrimaryActions({required this.status, required this.compact});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: status.isControllerReady
                ? () =>
                      amplificationController.setStreaming(!status.isStreaming)
                : null,
            icon: Icon(
              status.isStreaming
                  ? Icons.stop_circle_outlined
                  : Icons.power_settings_new,
              size: 19,
            ),
            label: Text(status.isStreaming ? 'STOP' : 'START'),
            style: ElevatedButton.styleFrom(
              backgroundColor: status.isStreaming
                  ? const Color(0xFFE65B5B)
                  : const Color(0xFFD4AF37),
              foregroundColor: const Color(0xFF111111),
              padding: EdgeInsets.symmetric(vertical: compact ? 11 : 15),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: status.isControllerReady && status.isStreaming
                ? () => amplificationController.setEnvironmentDetection(
                    !status.isEnvironmentDetectionEnabled,
                  )
                : null,
            icon: Icon(
              status.isEnvironmentDetectionEnabled
                  ? Icons.radar
                  : Icons.radar_outlined,
              size: 19,
            ),
            label: Text(
              status.isEnvironmentDetectionEnabled ? 'AUTO ON' : 'AUTO MODE',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: status.isEnvironmentDetectionEnabled
                  ? const Color(0xFFD4AF37)
                  : Colors.white,
              disabledForegroundColor: const Color(0xFF555555),
              side: BorderSide(
                color: status.isEnvironmentDetectionEnabled
                    ? const Color(0xFFD4AF37)
                    : const Color(0xFF3A3A3A),
              ),
              padding: EdgeInsets.symmetric(vertical: compact ? 11 : 15),
            ),
          ),
        ),
      ],
    );
  }
}

class _ModePicker extends StatelessWidget {
  final AmplificationStatus status;
  final bool compact;

  const _ModePicker({required this.status, required this.compact});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 8 : 10),
      decoration: BoxDecoration(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _ModeButton(
            label: 'Standard',
            color: const Color(0xFF6CA8FF),
            mode: 0,
            status: status,
            compact: compact,
          ),
          const SizedBox(width: 8),
          _ModeButton(
            label: 'Transport',
            color: const Color(0xFFFFA24A),
            mode: 1,
            status: status,
            compact: compact,
          ),
          const SizedBox(width: 8),
          _ModeButton(
            label: 'Talk',
            color: const Color(0xFF55D18A),
            mode: 2,
            status: status,
            compact: compact,
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final Color color;
  final int mode;
  final AmplificationStatus status;
  final bool compact;

  const _ModeButton({
    required this.label,
    required this.color,
    required this.mode,
    required this.status,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final selected = status.mode == mode;
    final enabled =
        status.isControllerReady && !status.isEnvironmentDetectionEnabled;

    return Expanded(
      child: InkWell(
        onTap: enabled
            ? () => amplificationController.setEnvironmentMode(mode)
            : null,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.symmetric(vertical: compact ? 8 : 11),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? color : const Color(0xFF343434),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: enabled || selected ? color : const Color(0xFF555555),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    color: enabled || selected
                        ? Colors.white
                        : const Color(0xFF666666),
                    fontSize: compact ? 10 : 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetectionReadout extends StatelessWidget {
  final AmplificationStatus status;
  final bool compact;

  const _DetectionReadout({required this.status, required this.compact});

  @override
  Widget build(BuildContext context) {
    final subtitle = status.isEnvironmentDetectionEnabled
        ? (status.detectedEnvironment.isEmpty
              ? 'Listening for environment changes'
              : '${status.detectedEnvironment} '
                    '${(status.confidence * 100).toStringAsFixed(0)}%')
        : 'Manual mode selection';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 14,
        vertical: compact ? 10 : 13,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF242424),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: status.modeColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            status.isEnvironmentDetectionEnabled
                ? Icons.graphic_eq
                : Icons.touch_app_outlined,
            color: status.modeColor,
            size: compact ? 18 : 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.isEnvironmentDetectionEnabled
                      ? 'LIVE ENV DETECTION'
                      : 'MANUAL MODE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 11 : 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: const Color(0xFF9A9A9A),
                    fontSize: compact ? 10 : 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolsTile extends StatelessWidget {
  final VoidCallback onTap;
  final bool compact;

  const _ToolsTile({required this.onTap, required this.compact});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 70 : 84,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 18),
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2A2A2A)),
          ),
          child: Row(
            children: [
              Container(
                width: compact ? 38 : 46,
                height: compact ? 38 : 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFD4AF37).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(Icons.build, color: Color(0xFFD4AF37)),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TOOLS',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'STT, TTS and future utilities',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Color(0xFF888888), fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF777777)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool compact;

  const _StatusPill({
    required this.label,
    required this.color,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: compact ? 9 : 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}
