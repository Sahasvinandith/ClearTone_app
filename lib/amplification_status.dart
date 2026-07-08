import 'package:flutter/material.dart';

class AmplificationStatus {
  final bool isStreaming;
  final bool isEnvironmentDetectionEnabled;
  final int mode;
  final String detectedEnvironment;
  final double confidence;

  const AmplificationStatus({
    this.isStreaming = false,
    this.isEnvironmentDetectionEnabled = false,
    this.mode = 0,
    this.detectedEnvironment = '',
    this.confidence = 0,
  });

  AmplificationStatus copyWith({
    bool? isStreaming,
    bool? isEnvironmentDetectionEnabled,
    int? mode,
    String? detectedEnvironment,
    double? confidence,
  }) {
    return AmplificationStatus(
      isStreaming: isStreaming ?? this.isStreaming,
      isEnvironmentDetectionEnabled:
          isEnvironmentDetectionEnabled ?? this.isEnvironmentDetectionEnabled,
      mode: mode ?? this.mode,
      detectedEnvironment: detectedEnvironment ?? this.detectedEnvironment,
      confidence: confidence ?? this.confidence,
    );
  }

  String get modeLabel {
    switch (mode) {
      case 1:
        return 'Transportation';
      case 2:
        return 'Conversation';
      default:
        return 'Standard';
    }
  }

  Color get modeColor {
    switch (mode) {
      case 1:
        return const Color(0xFFFFA24A);
      case 2:
        return const Color(0xFF55D18A);
      default:
        return const Color(0xFF6CA8FF);
    }
  }
}

final ValueNotifier<AmplificationStatus> amplificationStatusNotifier =
    ValueNotifier<AmplificationStatus>(const AmplificationStatus());
