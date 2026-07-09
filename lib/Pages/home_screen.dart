import 'package:flutter/material.dart';

import '../amplification_status.dart';
import '../audio_generator.dart';
import '../models/profile.dart';

class HomeScreen extends StatelessWidget {
  final Profile profile;
  final VoidCallback onOpenTools;
  final VoidCallback onOpenAmplification;
  final VoidCallback onOpenProfileTab;
  final VoidCallback onOpenProfileSelection;

  const HomeScreen({
    super.key,
    required this.profile,
    required this.onOpenTools,
    required this.onOpenAmplification,
    required this.onOpenProfileTab,
    required this.onOpenProfileSelection,
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
                  _TopActions(
                    compact: compact,
                    onOpenProfileTab: onOpenProfileTab,
                    onOpenProfileSelection: onOpenProfileSelection,
                  ),
                  SizedBox(height: compact ? 8 : 12),
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

class _TopActions extends StatelessWidget {
  final bool compact;
  final VoidCallback onOpenProfileTab;
  final VoidCallback onOpenProfileSelection;

  const _TopActions({
    required this.compact,
    required this.onOpenProfileTab,
    required this.onOpenProfileSelection,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: compact ? 42 : 48,
      child: Row(
        children: [
          _HeaderIconButton(
            icon: Icons.earbuds_battery_outlined,
            label: compact ? null : 'TEST BUDS',
            tooltip: 'Test earbuds',
            onTap: () => _showEarbudTestDialog(context),
          ),
          const Spacer(),
          PopupMenuButton<_ProfileAction>(
            tooltip: 'Profile options',
            color: const Color(0xFF1C1C1C),
            offset: const Offset(0, 46),
            onSelected: (action) {
              switch (action) {
                case _ProfileAction.profileTab:
                  onOpenProfileTab();
                case _ProfileAction.profileSelection:
                  onOpenProfileSelection();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _ProfileAction.profileTab,
                child: _ProfileMenuItem(
                  icon: Icons.person_outline,
                  label: 'PROFILE TAB',
                ),
              ),
              PopupMenuItem(
                value: _ProfileAction.profileSelection,
                child: _ProfileMenuItem(
                  icon: Icons.switch_account_outlined,
                  label: 'SELECT PROFILE',
                ),
              ),
            ],
            child: _HeaderIconButton(
              icon: Icons.account_circle_outlined,
              label: compact ? null : 'PROFILE',
              tooltip: 'Profile options',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showEarbudTestDialog(BuildContext context) async {
    final audioGenerator = AudioGenerator();

    Future<void> playTestTone(String channel) async {
      try {
        await audioGenerator.stopTone();
        await audioGenerator.playTone(
          frequency: 1000,
          amplitude: 45,
          channel: channel,
          duration: 1200,
        );
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play earbud test tone.')),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('TEST EARBUDS'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Play a short tone through each earbud.',
                style: TextStyle(color: Color(0xFF9A9A9A), fontSize: 13),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _EarTestButton(
                      icon: Icons.hearing,
                      label: 'LEFT EAR',
                      onPressed: () => playTestTone('left'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _EarTestButton(
                      icon: Icons.hearing,
                      label: 'RIGHT EAR',
                      onPressed: () => playTestTone('right'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                audioGenerator.stopTone();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('CLOSE'),
            ),
          ],
        );
      },
    );

    await audioGenerator.stopTone();
  }
}

enum _ProfileAction { profileTab, profileSelection }

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String? label;
  final String tooltip;
  final VoidCallback? onTap;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      height: 42,
      padding: EdgeInsets.symmetric(horizontal: label == null ? 11 : 13),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFFD4AF37), size: 21),
          if (label != null) ...[
            const SizedBox(width: 8),
            Text(
              label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ],
      ),
    );

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: content,
      ),
    );
  }
}

class _ProfileMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ProfileMenuItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFFD4AF37), size: 19),
        const SizedBox(width: 12),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}

class _EarTestButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _EarTestButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFD4AF37),
        side: const BorderSide(color: Color(0xFF3A3A3A)),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
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
