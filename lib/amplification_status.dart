import 'package:flutter/material.dart';

typedef AmplificationBoolCommand = Future<void> Function(bool enabled);
typedef AmplificationModeCommand = void Function(int mode);

class AmplificationStatus {
  final bool isStreaming;
  final bool isEnvironmentDetectionEnabled;
  final int mode;
  final String detectedEnvironment;
  final double confidence;
  final bool isControllerReady;

  const AmplificationStatus({
    this.isStreaming = false,
    this.isEnvironmentDetectionEnabled = false,
    this.mode = 0,
    this.detectedEnvironment = '',
    this.confidence = 0,
    this.isControllerReady = false,
  });

  AmplificationStatus copyWith({
    bool? isStreaming,
    bool? isEnvironmentDetectionEnabled,
    int? mode,
    String? detectedEnvironment,
    double? confidence,
    bool? isControllerReady,
  }) {
    return AmplificationStatus(
      isStreaming: isStreaming ?? this.isStreaming,
      isEnvironmentDetectionEnabled:
          isEnvironmentDetectionEnabled ?? this.isEnvironmentDetectionEnabled,
      mode: mode ?? this.mode,
      detectedEnvironment: detectedEnvironment ?? this.detectedEnvironment,
      confidence: confidence ?? this.confidence,
      isControllerReady: isControllerReady ?? this.isControllerReady,
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

class AmplificationController {
  AmplificationBoolCommand? _setStreaming;
  AmplificationBoolCommand? _setEnvironmentDetection;
  AmplificationModeCommand? _setEnvironmentMode;

  bool get isReady =>
      _setStreaming != null &&
      _setEnvironmentDetection != null &&
      _setEnvironmentMode != null;

  void register({
    required AmplificationBoolCommand setStreaming,
    required AmplificationBoolCommand setEnvironmentDetection,
    required AmplificationModeCommand setEnvironmentMode,
  }) {
    _setStreaming = setStreaming;
    _setEnvironmentDetection = setEnvironmentDetection;
    _setEnvironmentMode = setEnvironmentMode;
    amplificationStatusNotifier.value = amplificationStatusNotifier.value
        .copyWith(isControllerReady: true);
  }

  void unregister() {
    _setStreaming = null;
    _setEnvironmentDetection = null;
    _setEnvironmentMode = null;
    amplificationStatusNotifier.value = amplificationStatusNotifier.value
        .copyWith(isControllerReady: false);
  }

  Future<void> setStreaming(bool enabled) async {
    await _setStreaming?.call(enabled);
  }

  Future<void> setEnvironmentDetection(bool enabled) async {
    await _setEnvironmentDetection?.call(enabled);
  }

  void setEnvironmentMode(int mode) {
    _setEnvironmentMode?.call(mode);
  }
}

final AmplificationController amplificationController =
    AmplificationController();
