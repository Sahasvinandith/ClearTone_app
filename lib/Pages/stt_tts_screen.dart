import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

class SttTtsScreen extends StatefulWidget {
  const SttTtsScreen({super.key});

  @override
  State<SttTtsScreen> createState() => _SttTtsScreenState();
}

class _SttTtsScreenState extends State<SttTtsScreen> {
  // ---- STT ----
  final SpeechToText _stt = SpeechToText();
  bool _sttAvailable = false;
  bool _isListening = false;
  String _transcript = '';
  String? _sttLocaleId; // resolved at init time

  // ---- TTS ----
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;
  double _speechRate = 0.5;
  final TextEditingController _ttsController = TextEditingController();

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _initStt();
    _initTts();
  }

  @override
  void dispose() {
    _stt.stop();
    _tts.stop();
    _ttsController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // STT initialisation
  // -------------------------------------------------------------------------

  Future<void> _initStt() async {
    debugPrint('[STT] Calling initialize()...');
    final bool available = await _stt.initialize(
      onError: (error) {
        debugPrint('[STT] onError — errorMsg: ${error.errorMsg}, permanent: ${error.permanent}');
        if (mounted) setState(() => _isListening = false);
      },
      onStatus: (status) {
        debugPrint('[STT] onStatus: $status  (isListening=$_isListening)');
        // Only stop the UI toggle when we were actually listening.
        // Do NOT reset on 'notListening' fired during init or idle transitions.
        if (_isListening && (status == 'done' || status == 'notListening')) {
          if (mounted) setState(() => _isListening = false);
        }
      },
    );

    debugPrint('[STT] initialize() returned available=$available');

    if (available) {
      // Query available locales and pick the system default (first in list).
      final locales = await _stt.locales();
      debugPrint('[STT] Available locales: ${locales.map((l) => l.localeId).join(', ')}');
      // systemLocale() returns the device's current locale id.
      final systemLocale = await _stt.systemLocale();
      debugPrint('[STT] System locale: ${systemLocale?.localeId}');

      String? picked;
      if (systemLocale != null) {
        picked = systemLocale.localeId;
      } else if (locales.isNotEmpty) {
        picked = locales.first.localeId;
      }
      debugPrint('[STT] Using locale: $picked');
      if (mounted) setState(() => _sttLocaleId = picked);
    }

    if (mounted) setState(() => _sttAvailable = available);

    if (!available && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Speech recognition is not available on this device.'),
          backgroundColor: Color(0xFF1C1C1C),
        ),
      );
    }
  }

  // -------------------------------------------------------------------------
  // TTS initialisation
  // -------------------------------------------------------------------------

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      if (mounted) setState(() => _isSpeaking = true);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setErrorHandler((_) {
      if (mounted) setState(() => _isSpeaking = false);
    });
  }

  // -------------------------------------------------------------------------
  // STT actions
  // -------------------------------------------------------------------------

  Future<void> _toggleListening() async {
    debugPrint('[STT] _toggleListening called — _isListening=$_isListening, _sttAvailable=$_sttAvailable');

    if (_isListening) {
      debugPrint('[STT] Stopping listen session.');
      await _stt.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    // Ensure microphone permission before starting.
    final status = await Permission.microphone.request();
    debugPrint('[STT] Microphone permission status: $status');
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission is required for speech recognition.'),
            backgroundColor: Color(0xFF1C1C1C),
          ),
        );
      }
      return;
    }

    if (!_sttAvailable) {
      debugPrint('[STT] Not available — skipping listen.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Speech recognition is not available on this device.'),
            backgroundColor: Color(0xFF1C1C1C),
          ),
        );
      }
      return;
    }

    debugPrint('[STT] Starting listen()...');
    setState(() => _isListening = true);

    await _stt.listen(
      onResult: (result) {
        debugPrint('[STT] onResult: "${result.recognizedWords}" final=${result.finalResult}');
        if (mounted) {
          setState(() => _transcript = result.recognizedWords);
        }
      },
      localeId: _sttLocaleId, // null = let Android pick default
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 4),
        partialResults: true,
        cancelOnError: true,
      ),
    );

    debugPrint('[STT] listen() returned. stt.isListening=${_stt.isListening}');
  }

  void _clearTranscript() {
    setState(() => _transcript = '');
  }

  void _copyTranscript() {
    if (_transcript.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _transcript));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Transcript copied to clipboard.'),
        backgroundColor: Color(0xFF1C1C1C),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // TTS actions
  // -------------------------------------------------------------------------

  Future<void> _speak() async {
    final text = _ttsController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter some text to speak.'),
          backgroundColor: Color(0xFF1C1C1C),
        ),
      );
      return;
    }
    await _tts.setSpeechRate(_speechRate);
    await _tts.speak(text);
  }

  Future<void> _stopSpeaking() async {
    await _tts.stop();
    if (mounted) setState(() => _isSpeaking = false);
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1C),
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'SPEECH ASSISTANT',
          style: TextStyle(
            color: Colors.white,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSttCard(),
              const SizedBox(height: 20),
              _buildTtsCard(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // STT card
  // -------------------------------------------------------------------------

  Widget _buildSttCard() {
    final Color micColor = _isListening ? Colors.red : const Color(0xFFD4AF37);

    return _buildSectionCard(
      headerLabel: 'SPEECH TO TEXT',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Transcript display area with copy button overlay.
          Stack(
            children: [
              Container(
                constraints: const BoxConstraints(minHeight: 120),
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 14, 44, 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF161616),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF2A2A2A)),
                ),
                child: Text(
                  _transcript.isEmpty
                      ? 'Tap the mic to start listening...'
                      : _transcript,
                  style: TextStyle(
                    color: _transcript.isEmpty
                        ? const Color(0xFF444444)
                        : Colors.white,
                    fontSize: 15,
                    height: 1.5,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              // Copy button — top right of transcript box.
              Positioned(
                top: 6,
                right: 6,
                child: GestureDetector(
                  onTap: _copyTranscript,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1C),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF2A2A2A)),
                    ),
                    child: Icon(
                      Icons.copy_outlined,
                      size: 14,
                      color: _transcript.isNotEmpty
                          ? const Color(0xFFD4AF37)
                          : const Color(0xFF444444),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Clear button — right-aligned below transcript.
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _transcript.isNotEmpty ? _clearTranscript : null,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF666666),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.clear, size: 13),
              label: const Text(
                'CLEAR',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Mic button.
          Center(
            child: GestureDetector(
              onTap: _toggleListening,
              child: Container(
                height: 88,
                width: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: micColor.withValues(alpha: 0.1),
                  border: Border.all(color: micColor, width: 3),
                  boxShadow: _isListening
                      ? [
                          BoxShadow(
                            color: Colors.red.withValues(alpha: 0.3),
                            blurRadius: 16,
                            spreadRadius: 2,
                          ),
                        ]
                      : [],
                ),
                child: Center(
                  child: Icon(
                    _isListening ? Icons.mic : Icons.mic_none,
                    size: 40,
                    color: micColor,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          Center(
            child: Text(
              _isListening ? 'LISTENING...' : 'TAP MIC TO LISTEN',
              style: TextStyle(
                color: micColor,
                letterSpacing: 1.8,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // TTS card
  // -------------------------------------------------------------------------

  Widget _buildTtsCard() {
    return _buildSectionCard(
      headerLabel: 'TEXT TO SPEECH',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Text input field.
          TextField(
            controller: _ttsController,
            maxLines: 4,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: 'Enter text to speak...',
              hintStyle: const TextStyle(color: Color(0xFF444444), fontSize: 14),
              filled: true,
              fillColor: const Color(0xFF161616),
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFFD4AF37),
                  width: 1.5,
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Speech rate slider.
          _buildSliderRow(
            label: 'SPEECH RATE',
            valueLabel: _speechRate.toStringAsFixed(1),
            value: _speechRate,
            min: 0.1,
            max: 1.0,
            divisions: 9,
            onChanged: (v) {
              setState(() => _speechRate = v);
              _tts.setSpeechRate(v);
            },
          ),

          const SizedBox(height: 24),

          // SPEAK and STOP buttons.
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _speak,
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4AF37),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Text(
                        'SPEAK',
                        style: TextStyle(
                          color: Color(0xFF111111),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: _isSpeaking ? _stopSpeaking : null,
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _isSpeaking
                            ? const Color(0xFFD4AF37)
                            : const Color(0xFF444444),
                        width: 1.5,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        'STOP',
                        style: TextStyle(
                          color: _isSpeaking
                              ? const Color(0xFFD4AF37)
                              : const Color(0xFF444444),
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Shared card wrapper — mirrors _buildSettingsCard style in EnvironmentScreen
  // -------------------------------------------------------------------------

  Widget _buildSectionCard({
    required String headerLabel,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            headerLabel,
            style: const TextStyle(
              color: Color(0xFF666666),
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Slider row — matches EnvironmentScreen._buildSliderRow style
  // -------------------------------------------------------------------------

  Widget _buildSliderRow({
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF161616),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              child: Text(
                valueLabel,
                style: const TextStyle(
                  color: Color(0xFFD4AF37),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFFD4AF37),
            inactiveTrackColor: const Color(0xFF2A2A2A),
            thumbColor: const Color(0xFFD4AF37),
            overlayColor: const Color(0xFFD4AF37).withValues(alpha: 0.15),
            trackHeight: 3.0,
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
