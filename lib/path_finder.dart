import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Copies an asset file (like 'assets/my_sound.mp3') to a temporary file
/// on the device and returns its native file path.
Future<String> getFilePathFromAsset(String assetPath) async {
  final byteData = await rootBundle.load(assetPath);

  // Get a temporary directory
  final tempDir = await getTemporaryDirectory();
  // Create a file path
  final file = File('${tempDir.path}/${assetPath.split('/').last}');

  // Write the asset data to the file
  await file.writeAsBytes(
    byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
  );

  // Return the native path
  return file.path;
}
