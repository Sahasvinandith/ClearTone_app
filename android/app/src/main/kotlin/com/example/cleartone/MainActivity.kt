package com.example.cleartone

import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaPlayer
import android.media.AudioManager
import android.media.AudioDeviceInfo
import android.content.Intent
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.cleartone/audio"
    private var mediaPlayer: MediaPlayer? = null
    private var audioTrack: AudioTrack? = null
    private var speakerTts: TextToSpeech? = null
    private var pendingSpeakerTtsResult: MethodChannel.Result? = null
    private lateinit var amplificationOverlayManager: AmplificationOverlayManager

    // Assume 80 dB is our maximum reference level
    private val MAX_DB = 80.0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        amplificationOverlayManager = AmplificationOverlayManager(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
                call,
                result ->
            when (call.method) {
                "playFile" -> {
                    val filePath = call.argument<String>("filePath")
                    val channel = call.argument<String>("channel") ?: "left"
                    val amplitude = call.argument<Double>("amplitude")

                    if (filePath == null || amplitude == null) {
                        result.error(
                            "INVALID_ARGUMENT",
                            "File path and amplitude are required",
                            null
                        )
                    } else {
                        try {
                            playFile(filePath, channel, amplitude)
                            result.success(null)
                        } catch (e: Exception) {
                            Log.e("MediaPlayer", "Error playing file: $filePath", e)
                            result.error(
                                "PLAYBACK_ERROR",
                                "Failed to play file: ${e.message}",
                                null
                            )
                        }
                    }
                }
                "stopFile" -> {
                    stopFile()
                    result.success(null)
                }
                "playTone" -> {
                    val frequency = call.argument<Double>("frequency") ?: 1000.0
                    val amplitude = call.argument<Double>("amplitude") ?: 40.0
                    val channel = call.argument<String>("channel") ?: "left"
                    val duration = call.argument<Int>("duration") ?: 1000

                    playTone(frequency, amplitude, channel, duration)
                    result.success(null)
                }
                "stopTone" -> {
                    stopTone()
                    result.success(null)
                }
                "playLatencyChirp" -> {
                    val amplitude = call.argument<Double>("amplitude") ?: 76.0
                    val routeToSpeaker = call.argument<Boolean>("routeToSpeaker") ?: true
                    val chirpStartNs = playLatencyChirp(amplitude, routeToSpeaker)
                    result.success(chirpStartNs)
                }
                "getAudioInputDevices" -> {
                    try {
                        val devices = getAudioInputDevices()
                        result.success(devices)
                    } catch (e: Exception) {
                        result.error("DEVICE_ERROR", e.message, null)
                    }
                }
                "getDeviceInfo" -> {
                    try {
                        result.success(getDeviceInfo())
                    } catch (e: Exception) {
                        result.error("DEVICE_INFO_ERROR", e.message, null)
                    }
                }
                "enableBluetoothSco" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    enableBluetoothSco(enable)
                    result.success(null)
                }
                "enablePhoneSpeakerForTts" -> {
                    enablePhoneSpeakerForTts()
                    result.success(null)
                }
                "resetPhoneSpeakerForTts" -> {
                    resetPhoneSpeakerForTts()
                    result.success(null)
                }
                "speakTextOnPhoneSpeaker" -> {
                    val text = call.argument<String>("text") ?: ""
                    val localeId = call.argument<String>("localeId") ?: "en-US"
                    val speechRate = call.argument<Double>("speechRate") ?: 0.5
                    speakTextOnPhoneSpeaker(text, localeId, speechRate.toFloat(), result)
                }
                "stopTextOnPhoneSpeaker" -> {
                    stopTextOnPhoneSpeaker()
                    result.success(null)
                }
                "startAmplificationForegroundService" -> {
                    try {
                        startAmplificationForegroundService()
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Failed to start amplification foreground service", e)
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                "stopAmplificationForegroundService" -> {
                    try {
                        stopAmplificationForegroundService()
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Failed to stop amplification foreground service", e)
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                "canDrawAmplificationOverlay" -> {
                    result.success(amplificationOverlayManager.canDrawOverlays())
                }
                "requestAmplificationOverlayPermission" -> {
                    amplificationOverlayManager.requestOverlayPermission()
                    result.success(null)
                }
                "showAmplificationOverlay" -> {
                    val shown = amplificationOverlayManager.show(
                        call.argument<String>("mode") ?: "Standard",
                        call.argument<Boolean>("autoDetectEnabled") ?: false,
                        call.argument<String>("detectedEnvironment") ?: "",
                        call.argument<Double>("confidence") ?: 0.0
                    )
                    result.success(shown)
                }
                "updateAmplificationOverlay" -> {
                    val updated = amplificationOverlayManager.update(
                        call.argument<String>("mode") ?: "Standard",
                        call.argument<Boolean>("autoDetectEnabled") ?: false,
                        call.argument<String>("detectedEnvironment") ?: "",
                        call.argument<Double>("confidence") ?: 0.0
                    )
                    result.success(updated)
                }
                "hideAmplificationOverlay" -> {
                    val resetDismissed = call.argument<Boolean>("resetDismissed") ?: true
                    amplificationOverlayManager.hide(resetDismissed)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startAmplificationForegroundService() {
        val intent = Intent(this, AmplificationForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopAmplificationForegroundService() {
        stopService(Intent(this, AmplificationForegroundService::class.java))
    }

    private fun getAudioInputDevices(): List<Map<String, Any>> {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val deviceList = mutableListOf<Map<String, Any>>()
        
        for (device in devices) {
            val typeStr = when (device.type) {
                AudioDeviceInfo.TYPE_BUILTIN_MIC -> "Built-in Mic"
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth"
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth"
                AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired Headset"
                AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Headset"
                AudioDeviceInfo.TYPE_USB_DEVICE -> "USB Mic"
                else -> "Other (${device.type})"
            }
            
            val name = if (device.productName.isNullOrEmpty()) typeStr else "${device.productName} ($typeStr)"
            
            val map = mapOf(
                "id" to device.id,
                "name" to name.toString(),
                "type" to device.type
            )
            deviceList.add(map)
        }
        
        return deviceList
    }

    // For metadata/session_config.json + metadata/device_info.json
    // (docs/validation.md). App version comes from the installed package
    // rather than a hardcoded string so it always matches the running build.
    private fun getDeviceInfo(): Map<String, Any> {
        val appVersion = try {
            val pInfo = packageManager.getPackageInfo(packageName, 0)
            @Suppress("DEPRECATION")
            "${pInfo.versionName} (${pInfo.versionCode})"
        } catch (e: Exception) {
            "unknown"
        }
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "phone_model" to Build.MODEL,
            "android_version" to Build.VERSION.RELEASE,
            "android_sdk_int" to Build.VERSION.SDK_INT,
            "app_version" to appVersion
        )
    }

    private fun enableBluetoothSco(enable: Boolean) {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        try {
            if (enable) {
                Log.d("MainActivity", "Starting Bluetooth SCO")
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true
                try {
                    audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                } catch (e: SecurityException) {
                    Log.e("MainActivity", "SecurityException setting mode IN_COMMUNICATION: ${e.message}")
                }
            } else {
                Log.d("MainActivity", "Stopping Bluetooth SCO")
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
                try {
                    audioManager.mode = AudioManager.MODE_NORMAL
                } catch (e: SecurityException) {
                    Log.e("MainActivity", "SecurityException setting mode NORMAL: ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "Error managing Bluetooth SCO: ${e.message}")
        }
    }

    private fun enablePhoneSpeakerForTts() {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        try {
            audioManager.stopBluetoothSco()
            audioManager.isBluetoothScoOn = false

            try {
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            } catch (e: SecurityException) {
                Log.e("MainActivity", "SecurityException setting mode IN_COMMUNICATION for TTS: ${e.message}")
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val speaker = audioManager
                    .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (speaker != null) {
                    audioManager.setCommunicationDevice(speaker)
                }
            }

            audioManager.isSpeakerphoneOn = true
            Log.d("MainActivity", "TTS routed to phone speaker")
        } catch (e: Exception) {
            Log.e("MainActivity", "Error routing TTS to phone speaker: ${e.message}")
        }
    }

    private fun resetPhoneSpeakerForTts() {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            }
            audioManager.isSpeakerphoneOn = false
            try {
                audioManager.mode = AudioManager.MODE_NORMAL
            } catch (e: SecurityException) {
                Log.e("MainActivity", "SecurityException resetting mode after TTS: ${e.message}")
            }
            Log.d("MainActivity", "TTS speaker route reset")
        } catch (e: Exception) {
            Log.e("MainActivity", "Error resetting TTS speaker route: ${e.message}")
        }
    }

    private fun speakTextOnPhoneSpeaker(
        text: String,
        localeId: String,
        speechRate: Float,
        result: MethodChannel.Result
    ) {
        if (text.isBlank()) {
            result.error("INVALID_ARGUMENT", "Text is empty.", null)
            return
        }

        pendingSpeakerTtsResult?.success(null)
        pendingSpeakerTtsResult = result
        enablePhoneSpeakerForTts()

        val utteranceId = "cleartone_tts_${System.currentTimeMillis()}"
        val speak: (TextToSpeech) -> Unit = { tts ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                tts.setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
            }
            tts.language = localeFromId(localeId)
            tts.setSpeechRate(speechRate.coerceIn(0.1f, 2.0f))
            tts.setOnUtteranceProgressListener(
                object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) = Unit

                    override fun onDone(utteranceId: String?) {
                        runOnUiThread {
                            pendingSpeakerTtsResult?.success(null)
                            pendingSpeakerTtsResult = null
                            resetPhoneSpeakerForTts()
                        }
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        onError(utteranceId, TextToSpeech.ERROR)
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        runOnUiThread {
                            pendingSpeakerTtsResult?.error(
                                "TTS_ERROR",
                                "Android TTS failed with code $errorCode",
                                null
                            )
                            pendingSpeakerTtsResult = null
                            resetPhoneSpeakerForTts()
                        }
                    }
                }
            )

            val params = Bundle()
            val status = tts.speak(text, TextToSpeech.QUEUE_FLUSH, params, utteranceId)
            if (status == TextToSpeech.ERROR) {
                pendingSpeakerTtsResult?.error("TTS_ERROR", "Android TTS failed to start.", null)
                pendingSpeakerTtsResult = null
                resetPhoneSpeakerForTts()
            }
        }

        val existingTts = speakerTts
        if (existingTts != null) {
            speak(existingTts)
            return
        }

        speakerTts = TextToSpeech(this) { status ->
            runOnUiThread {
                val initializedTts = speakerTts
                if (status == TextToSpeech.SUCCESS && initializedTts != null) {
                    speak(initializedTts)
                } else {
                    pendingSpeakerTtsResult?.error("TTS_INIT_ERROR", "Android TTS could not initialize.", null)
                    pendingSpeakerTtsResult = null
                    resetPhoneSpeakerForTts()
                }
            }
        }
    }

    private fun stopTextOnPhoneSpeaker() {
        speakerTts?.stop()
        pendingSpeakerTtsResult?.success(null)
        pendingSpeakerTtsResult = null
        resetPhoneSpeakerForTts()
    }

    private fun localeFromId(localeId: String): Locale {
        val parts = localeId.split("-", "_")
        return when {
            parts.size >= 2 -> Locale(parts[0], parts[1])
            parts.isNotEmpty() -> Locale(parts[0])
            else -> Locale.US
        }
    }

    private fun playFile(filePath: String, channel: String, amplitudeDb: Double) {
        stopFile()

        // Convert DB to a linear volume scalar (0.0 to 1.0)
        // We map our dB range (0-80) to the linear scale.
        val volume = 10.0.pow((amplitudeDb - MAX_DB) / 20.0).toFloat().coerceIn(0.0f, 1.0f)

        mediaPlayer =
            MediaPlayer().apply {
                setDataSource(filePath)
                isLooping = true

                val leftVolume = if (channel == "right") 0.0f else volume
                val rightVolume = if (channel == "left") 0.0f else volume

                setVolume(leftVolume, rightVolume)

                prepare()
                start()
            }
    }

    private fun stopFile() {
        mediaPlayer?.stop()
        mediaPlayer?.release()
        mediaPlayer = null
    }

    private fun playTone(frequency: Double, amplitudeDb: Double, channel: String, duration: Int) {
        val sampleRate = 44100
        val numSamples = (duration * sampleRate) / 1000
        val samples = ShortArray(numSamples * 2) // Stereo

        // Convert dB to linear amplitude, treating MAX_DB as 0 dBFS (full scale)
        // A safety margin of 0.95 is added to prevent clipping.
        val linearAmplitude = (10.0.pow((amplitudeDb - MAX_DB) / 20.0) * 0.95).toFloat()

        for (i in 0 until numSamples) {
            val sampleValue =
                (sin(2.0 * PI * frequency * i / sampleRate) * linearAmplitude * Short.MAX_VALUE)
                    .toInt()
                    .toShort()

            samples[i * 2] = if (channel == "left") sampleValue else 0
            samples[i * 2 + 1] = if (channel == "right") sampleValue else 0
        }

        val bufferSize = samples.size * 2

        audioTrack?.release() // Release previous track if any

        audioTrack =
            AudioTrack.Builder()
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()

        audioTrack?.write(samples, 0, samples.size)
        audioTrack?.play()
    }

    private fun stopTone() {
        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null
    }

    private fun playLatencyChirp(amplitudeDb: Double, routeToSpeaker: Boolean): Long {
        stopTone()

        val sampleRate = 48000
        val leadSilenceMs = 120
        val chirpMs = 40
        val tailSilenceMs = 120
        val leadSamples = (leadSilenceMs * sampleRate) / 1000
        val chirpSamples = (chirpMs * sampleRate) / 1000
        val tailSamples = (tailSilenceMs * sampleRate) / 1000
        val totalSamples = leadSamples + chirpSamples + tailSamples
        val samples = ShortArray(totalSamples * 2)
        val linearAmplitude = (10.0.pow((amplitudeDb - MAX_DB) / 20.0) * 0.90)
            .toFloat()
            .coerceIn(0.0f, 0.95f)
        val f0 = 1800.0
        val f1 = 7600.0
        val durationSec = chirpMs / 1000.0
        val k = (f1 - f0) / durationSec
        val fadeSamples = (0.004 * sampleRate).toInt().coerceAtLeast(1)

        for (i in 0 until chirpSamples) {
            val t = i.toDouble() / sampleRate
            val phase = 2.0 * PI * (f0 * t + 0.5 * k * t * t)
            val envelope =
                when {
                    i < fadeSamples -> 0.5 - 0.5 * cos(PI * i.toDouble() / fadeSamples)
                    i >= chirpSamples - fadeSamples -> {
                        val j = chirpSamples - 1 - i
                        0.5 - 0.5 * cos(PI * j.toDouble() / fadeSamples)
                    }
                    else -> 1.0
                }
            val sampleValue =
                (sin(phase) * envelope * linearAmplitude * Short.MAX_VALUE)
                    .toInt()
                    .toShort()
            val stereoIndex = (leadSamples + i) * 2
            samples[stereoIndex] = sampleValue
            samples[stereoIndex + 1] = sampleValue
        }

        audioTrack =
            AudioTrack.Builder()
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(samples.size * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()

        if (routeToSpeaker && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
            val speaker = audioManager
                .getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            if (speaker != null) {
                audioTrack?.preferredDevice = speaker
            }
        }

        audioTrack?.write(samples, 0, samples.size)
        val playbackStartNs = System.nanoTime()
        audioTrack?.play()
        return playbackStartNs + leadSilenceMs * 1_000_000L
    }
}
