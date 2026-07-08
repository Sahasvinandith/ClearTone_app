import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../speech/exceptions.dart';
import '../speech/phone_speaker_router.dart';
import '../speech/speech_config.dart';
import '../speech/speech_service.dart';

class SttTtsScreen extends StatefulWidget {
  const SttTtsScreen({super.key});

  @override
  State<SttTtsScreen> createState() => _SttTtsScreenState();
}

class _SttTtsScreenState extends State<SttTtsScreen> {
  // ---- Mode ----
  bool _isOnlineMode = false;
  String _selectedLocale = 'en-US';

  // ---- Shared ----
  String _transcript = '';
  final TextEditingController _ttsController = TextEditingController();

  // ---- Offline STT ----
  final SpeechToText _stt = SpeechToText();
  bool _sttAvailable = false;
  bool _isListening = false;
  String? _sttLocaleId;

  // ---- Offline TTS ----
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;
  double _speechRate = 0.5;

  // ---- Online (GCP) ----
  SpeechService? _speechService;
  bool _isRecording = false;
  bool _isProcessing = false;
  bool _onlineSpeaking = false;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _initOfflineStt();
    _initOfflineTts();
  }

  @override
  void dispose() {
    _stt.stop();
    _tts.stop();
    _ttsController.dispose();
    _speechService?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Offline STT init
  // ---------------------------------------------------------------------------

  Future<void> _initOfflineStt() async {
    debugPrint('[STT] Calling initialize()...');
    final bool available = await _stt.initialize(
      onError: (error) {
        debugPrint(
          '[STT] onError — errorMsg: ${error.errorMsg}, permanent: ${error.permanent}',
        );
        if (mounted) setState(() => _isListening = false);
      },
      onStatus: (status) {
        debugPrint('[STT] onStatus: $status  (isListening=$_isListening)');
        if (_isListening && (status == 'done' || status == 'notListening')) {
          if (mounted) setState(() => _isListening = false);
        }
      },
    );

    debugPrint('[STT] initialize() returned available=$available');

    if (available) {
      final locales = await _stt.locales();
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
  }

  // ---------------------------------------------------------------------------
  // Offline TTS init
  // ---------------------------------------------------------------------------

  Future<void> _initOfflineTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.setAudioAttributesForNavigation();
    _tts.setStartHandler(() {
      if (mounted) setState(() => _isSpeaking = true);
    });
    _tts.setCompletionHandler(() {
      PhoneSpeakerRouter.resetAfterTts();
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setCancelHandler(() {
      PhoneSpeakerRouter.resetAfterTts();
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setErrorHandler((_) {
      PhoneSpeakerRouter.resetAfterTts();
      if (mounted) setState(() => _isSpeaking = false);
    });
  }

  // ---------------------------------------------------------------------------
  // Mode toggle
  // ---------------------------------------------------------------------------

  Future<void> _switchMode(bool online) async {
    // Stop any active sessions before switching.
    if (_isListening) {
      await _stt.stop();
    }
    if (_isRecording) {
      await _speechService?.stt.cancel();
    }
    await _tts.stop();
    await _speechService?.tts.stop();

    // Lazy-init the GCP service the first time online mode is activated.
    if (online && _speechService == null) {
      try {
        _speechService = SpeechService();
        _speechService!.setLanguage(_selectedLocale);
      } catch (e) {
        _showError(e is SpeechException ? e.message : e.toString());
        return;
      }
    }

    setState(() {
      _isOnlineMode = online;
      _isListening = false;
      _isRecording = false;
      _isProcessing = false;
      _isSpeaking = false;
      _onlineSpeaking = false;
    });
  }

  void _onLocaleSelected(String locale) {
    setState(() => _selectedLocale = locale);
    _speechService?.setLanguage(locale);
  }

  // ---------------------------------------------------------------------------
  // Offline STT actions
  // ---------------------------------------------------------------------------

  Future<void> _toggleOfflineListening() async {
    debugPrint(
      '[STT] _toggleListening called — _isListening=$_isListening, _sttAvailable=$_sttAvailable',
    );

    if (_isListening) {
      await _stt.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    final status = await Permission.microphone.request();
    debugPrint('[STT] Microphone permission status: $status');
    if (!status.isGranted) {
      _showError('Microphone permission is required.');
      return;
    }

    if (!_sttAvailable) {
      _showError('Speech recognition is not available on this device.');
      return;
    }

    debugPrint('[STT] Starting listen()...');
    setState(() => _isListening = true);

    await _stt.listen(
      onResult: (result) {
        debugPrint(
          '[STT] onResult: "${result.recognizedWords}" final=${result.finalResult}',
        );
        if (mounted) setState(() => _transcript = result.recognizedWords);
      },
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 4),
        partialResults: true,
        cancelOnError: true,
        localeId: _sttLocaleId,
      ),
    );

    debugPrint('[STT] listen() returned. stt.isListening=${_stt.isListening}');
  }

  // ---------------------------------------------------------------------------
  // Online STT actions
  // ---------------------------------------------------------------------------

  Future<void> _toggleOnlineListening() async {
    final service = _speechService;
    if (service == null) return;

    if (_isRecording) {
      // Stop recording and transcribe.
      setState(() {
        _isRecording = false;
        _isProcessing = true;
      });
      try {
        final result = await service.stt.stopAndTranscribe();
        if (mounted) {
          setState(() {
            // Append to transcript so multiple recordings accumulate.
            if (_transcript.isNotEmpty) _transcript += ' ';
            _transcript += result.transcript;
            _isProcessing = false;
          });
        }
      } on SpeechException catch (e) {
        if (mounted) {
          setState(() => _isProcessing = false);
          _showError(e.message);
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isProcessing = false);
          _showError(e.toString());
        }
      }
    } else {
      // Start recording.
      try {
        await service.stt.startRecording();
        if (mounted) setState(() => _isRecording = true);
      } on SpeechException catch (e) {
        _showError(e.message);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Offline TTS actions
  // ---------------------------------------------------------------------------

  Future<void> _offlineSpeak() async {
    final text = _ttsController.text.trim();
    if (text.isEmpty) {
      _showError('Please enter some text to speak.');
      return;
    }
    if (PhoneSpeakerRouter.supportsNativeSpeakerTts) {
      setState(() => _isSpeaking = true);
      try {
        await PhoneSpeakerRouter.speakTextOnSpeaker(
          text: text,
          localeId: _selectedLocale,
          speechRate: _speechRate,
        );
      } on PlatformException catch (e) {
        _showError(e.message ?? 'Text-to-speech failed.');
      } finally {
        if (mounted) setState(() => _isSpeaking = false);
      }
      return;
    }

    await PhoneSpeakerRouter.enableForTts();
    await _tts.setAudioAttributesForNavigation();
    await _tts.setSpeechRate(_speechRate);
    await _tts.speak(text);
  }

  Future<void> _offlineStop() async {
    await PhoneSpeakerRouter.stopTextOnSpeaker();
    await _tts.stop();
    await PhoneSpeakerRouter.resetAfterTts();
    if (mounted) setState(() => _isSpeaking = false);
  }

  // ---------------------------------------------------------------------------
  // Online TTS actions
  // ---------------------------------------------------------------------------

  Future<void> _onlineSpeak() async {
    final service = _speechService;
    if (service == null) return;
    final text = _ttsController.text.trim();
    if (text.isEmpty) {
      _showError('Please enter some text to speak.');
      return;
    }
    setState(() => _onlineSpeaking = true);
    try {
      await service.tts.speak(text);
    } on SpeechException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) setState(() => _onlineSpeaking = false);
    }
  }

  Future<void> _onlineStop() async {
    await _speechService?.tts.stop();
    if (mounted) setState(() => _onlineSpeaking = false);
  }

  // ---------------------------------------------------------------------------
  // Shared transcript helpers
  // ---------------------------------------------------------------------------

  void _clearTranscript() => setState(() => _transcript = '');

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

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFF1C1C1C)),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

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
              _buildModeToggle(),
              const SizedBox(height: 16),
              if (_isOnlineMode) _buildLocaleSelector(),
              if (_isOnlineMode) const SizedBox(height: 20),
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

  // ---------------------------------------------------------------------------
  // Mode toggle pill
  // ---------------------------------------------------------------------------

  Widget _buildModeToggle() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Row(
        children: [
          _buildToggleOption(
            'OFFLINE',
            !_isOnlineMode,
            () => _switchMode(false),
          ),
          _buildToggleOption('ONLINE', _isOnlineMode, () => _switchMode(true)),
        ],
      ),
    );
  }

  Widget _buildToggleOption(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFD4AF37) : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFF111111)
                    : const Color(0xFF666666),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Locale selector (online only)
  // ---------------------------------------------------------------------------

  Widget _buildLocaleSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: SpeechConfig.supportedLocales.map((locale) {
          final selected = locale == _selectedLocale;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => _onLocaleSelected(locale),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFFD4AF37)
                      : const Color(0xFF1C1C1C),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFFD4AF37)
                        : const Color(0xFF2A2A2A),
                  ),
                ),
                child: Text(
                  locale,
                  style: TextStyle(
                    color: selected
                        ? const Color(0xFF111111)
                        : const Color(0xFF888888),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // STT card
  // ---------------------------------------------------------------------------

  Widget _buildSttCard() {
    return _buildSectionCard(
      headerLabel: 'SPEECH TO TEXT',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTranscriptDisplay(),
          const SizedBox(height: 8),
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
          _isOnlineMode ? _buildOnlineMicButton() : _buildOfflineMicButton(),
          const SizedBox(height: 12),
          Center(child: _buildMicStatusText()),
        ],
      ),
    );
  }

  Widget _buildTranscriptDisplay() {
    String placeholder;
    if (_isOnlineMode) {
      placeholder = _isProcessing
          ? 'Processing...'
          : 'Tap the mic, speak, tap again to transcribe...';
    } else {
      placeholder = 'Tap the mic to start listening...';
    }

    return Stack(
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
          child: _isProcessing
              ? Row(
                  children: const [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFFD4AF37),
                      ),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Processing...',
                      style: TextStyle(
                        color: Color(0xFF666666),
                        fontSize: 14,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                )
              : Text(
                  _transcript.isEmpty ? placeholder : _transcript,
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
    );
  }

  Widget _buildOfflineMicButton() {
    final Color micColor = _isListening ? Colors.red : const Color(0xFFD4AF37);
    return Center(
      child: GestureDetector(
        onTap: _toggleOfflineListening,
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
    );
  }

  Widget _buildOnlineMicButton() {
    Color micColor;
    IconData micIcon;
    List<BoxShadow> shadows = [];

    if (_isProcessing) {
      micColor = const Color(0xFF4FC3F7);
      micIcon = Icons.hourglass_empty;
    } else if (_isRecording) {
      micColor = Colors.red;
      micIcon = Icons.mic;
      shadows = [
        BoxShadow(
          color: Colors.red.withValues(alpha: 0.3),
          blurRadius: 16,
          spreadRadius: 2,
        ),
      ];
    } else {
      micColor = const Color(0xFFD4AF37);
      micIcon = Icons.mic_none;
    }

    return Center(
      child: GestureDetector(
        onTap: _isProcessing ? null : _toggleOnlineListening,
        child: Container(
          height: 88,
          width: 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: micColor.withValues(alpha: 0.1),
            border: Border.all(color: micColor, width: 3),
            boxShadow: shadows,
          ),
          child: Center(child: Icon(micIcon, size: 40, color: micColor)),
        ),
      ),
    );
  }

  Widget _buildMicStatusText() {
    String label;
    Color color;

    if (_isOnlineMode) {
      if (_isProcessing) {
        label = 'PROCESSING...';
        color = const Color(0xFF4FC3F7);
      } else if (_isRecording) {
        label = 'RECORDING... TAP TO STOP';
        color = Colors.red;
      } else {
        label = 'TAP MIC TO RECORD';
        color = const Color(0xFFD4AF37);
      }
    } else {
      label = _isListening ? 'LISTENING...' : 'TAP MIC TO LISTEN';
      color = _isListening ? Colors.red : const Color(0xFFD4AF37);
    }

    return Text(
      label,
      style: TextStyle(
        color: color,
        letterSpacing: 1.8,
        fontWeight: FontWeight.bold,
        fontSize: 12,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // TTS card
  // ---------------------------------------------------------------------------

  Widget _buildTtsCard() {
    return _buildSectionCard(
      headerLabel: 'TEXT TO SPEECH',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
              hintStyle: const TextStyle(
                color: Color(0xFF444444),
                fontSize: 14,
              ),
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
          if (!_isOnlineMode)
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
          if (!_isOnlineMode) const SizedBox(height: 24),
          if (_isOnlineMode) const SizedBox(height: 4),
          _buildSpeakStopButtons(),
        ],
      ),
    );
  }

  Widget _buildSpeakStopButtons() {
    final bool speaking = _isOnlineMode ? _onlineSpeaking : _isSpeaking;
    final VoidCallback onSpeak = _isOnlineMode ? _onlineSpeak : _offlineSpeak;
    final VoidCallback? onStop = speaking
        ? (_isOnlineMode ? _onlineStop : _offlineStop)
        : null;

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: onSpeak,
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
            onTap: onStop,
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: speaking
                      ? const Color(0xFFD4AF37)
                      : const Color(0xFF444444),
                  width: 1.5,
                ),
              ),
              child: Center(
                child: Text(
                  'STOP',
                  style: TextStyle(
                    color: speaking
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
    );
  }

  // ---------------------------------------------------------------------------
  // Shared card wrapper
  // ---------------------------------------------------------------------------

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
