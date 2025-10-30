import 'package:flutter/material.dart';
import 'path_finder.dart' as pathf;
import 'audio_generator.dart';
import './Pages/screen_test.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audiometry App',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const AudioTestScreen(),
    );
  }
}

class AudioTestScreen extends StatefulWidget {
  const AudioTestScreen({Key? key}) : super(key: key);

  @override
  State<AudioTestScreen> createState() => _AudioTestScreenState();
}

class _AudioTestScreenState extends State<AudioTestScreen> {
  bool _isLeftPlaying = false;
  bool _isRightPlaying = false;
  bool _audioLoaded = true;
  String _statusMessage = 'Audio Loaded';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Check Earphones'), centerTitle: true),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Status Icon
              Icon(
                _audioLoaded ? Icons.check_circle : Icons.error,
                size: 80,
                color: _audioLoaded ? Colors.green : Colors.orange,
              ),

              const SizedBox(height: 24),

              // Status Message
              Text(
                _statusMessage,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 48),

              // Important Note Card
              Card(
                color: Colors.blue.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Icon(
                        Icons.headset,
                        size: 48,
                        color: Colors.blue.shade700,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Please wear headphones',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ensure they are properly positioned:\nLeft = L, Right = R',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.blue.shade700),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 48),

              ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ScreenTest()),
                  );
                },
                child: const Text("Go to Screen Test"),
              ),
              // Left Ear Button
              SizedBox(
                width: 220,
                height: 70,
                child: ElevatedButton(
                  onPressed: () async {
                    // 1. Invoking audio_generator.dart to activate playtone function
                    AudioGenerator().playTone(
                      frequency: 2000,
                      amplitude: 0,
                      channel: 'left',
                      duration: 5000,
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isLeftPlaying ? Icons.stop_circle : Icons.play_circle,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'LEFT EAR',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _isLeftPlaying ? 'Playing...' : 'Tap to play',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Right Ear Button
              SizedBox(
                width: 220,
                height: 70,
                child: ElevatedButton(
                  onPressed: () async {
                    String nativePath = await pathf.getFilePathFromAsset(
                      'assets/audio/sample.wav',
                    );

                    // 2. Now, pass that native path to your audio generator
                    AudioGenerator().playFile(
                      filePath: nativePath,
                      channel: 'right', // or 'right'
                    );
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isRightPlaying ? Icons.stop_circle : Icons.play_circle,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'RIGHT EAR',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _isRightPlaying ? 'Playing...' : 'Tap to play',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ],
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
