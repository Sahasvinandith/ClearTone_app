import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Local cache for synthesised TTS audio files.
///
/// Cache key = SHA-256 of "$text|$voiceName".
/// Files are stored as .mp3 in `<tmpDir>/stt_tts_cache/`.
class TtsAudioCache {
  static const String _cacheDir = 'stt_tts_cache';

  Future<Directory> _dir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/$_cacheDir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _key(String text, String voiceName) {
    final bytes = utf8.encode('$text|$voiceName');
    return sha256.convert(bytes).toString();
  }

  /// Returns cached bytes for [text]+[voiceName], or null if not cached.
  Future<Uint8List?> get(String text, String voiceName) async {
    final file = File('${(await _dir()).path}/${_key(text, voiceName)}.mp3');
    if (await file.exists()) return file.readAsBytes();
    return null;
  }

  /// Stores [bytes] under [text]+[voiceName].
  Future<void> put(String text, String voiceName, Uint8List bytes) async {
    final file = File('${(await _dir()).path}/${_key(text, voiceName)}.mp3');
    await file.writeAsBytes(bytes);
  }

  /// Deletes all cached audio files.
  Future<void> clear() async {
    final dir = await _dir();
    await for (final entity in dir.list()) {
      await entity.delete();
    }
  }
}
