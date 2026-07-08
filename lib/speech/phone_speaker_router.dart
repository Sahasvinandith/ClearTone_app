import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Routes short TTS playback to the phone loudspeaker on Android.
class PhoneSpeakerRouter {
  const PhoneSpeakerRouter._();

  static const MethodChannel _channel = MethodChannel('com.cleartone/audio');

  static bool get supportsNativeSpeakerTts => Platform.isAndroid;

  static Future<void> enableForTts() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<void>('enablePhoneSpeakerForTts');
    } on PlatformException catch (e) {
      debugPrint('[TTS] Failed to enable phone speaker: ${e.message}');
    }
  }

  static Future<void> resetAfterTts() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<void>('resetPhoneSpeakerForTts');
    } on PlatformException catch (e) {
      debugPrint('[TTS] Failed to reset phone speaker route: ${e.message}');
    }
  }

  static Future<void> speakTextOnSpeaker({
    required String text,
    required String localeId,
    required double speechRate,
  }) async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<void>('speakTextOnPhoneSpeaker', {
        'text': text,
        'localeId': localeId,
        'speechRate': speechRate,
      });
    } on PlatformException catch (e) {
      debugPrint('[TTS] Failed to speak on phone speaker: ${e.message}');
      rethrow;
    }
  }

  static Future<void> stopTextOnSpeaker() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod<void>('stopTextOnPhoneSpeaker');
    } on PlatformException catch (e) {
      debugPrint('[TTS] Failed to stop phone speaker TTS: ${e.message}');
    }
  }
}
