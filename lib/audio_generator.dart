import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class AudioGenerator {
  static const platform = MethodChannel('com.cleartone/audio');

  /// Plays a specified audio file, panned to the left or right channel.
  Future<void> playFile({
    required String filePath, // The *native* path to the file on the device
    required String channel, // 'left' or 'right'
    required double amplitude, // dB (e.g., 40)
  }) async {
    try {
      await platform.invokeMethod('playFile', {
        'filePath': filePath,
        'channel': channel,
        'amplitude': amplitude,
      });
    } catch (e) {
      debugPrint('Error playing file: $e');
      rethrow;
    }
  }

  /// Stops the currently playing audio file.
  Future<void> stopFile() async {
    await platform.invokeMethod('stopFile');
  }

  Future<void> playTone({
    required double frequency, // Hz (e.g., 1000)
    required double amplitude, // dB (e.g., 40)
    required String channel, // 'left' or 'right'
    required int duration, // milliseconds
  }) async {
    try {
      debugPrint("Tone playing");
      await platform.invokeMethod('playTone', {
        'frequency': frequency,
        'amplitude': amplitude,
        'channel': channel,
        'duration': duration,
      });
    } catch (e) {
      debugPrint('Error playing tone: $e');
      rethrow;
    }
  }

  Future<void> stopTone() async {
    await platform.invokeMethod('stopTone');
  }
}
