package com.example.cleartone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioDeviceInfo
import android.media.AudioTrack
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.sin

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.cleartone/audio"
    private var mediaPlayer: MediaPlayer? = null
    private var audioTrack: AudioTrack? = null

    // Assume 80 dB is our maximum reference level
    private val MAX_DB = 80.0

    // Bug 1: SCO state machine — pending result resolved by BroadcastReceiver
    private var pendingScoResult: MethodChannel.Result? = null
    private var methodChannel: MethodChannel? = null

    // Bug 5: AudioFocus
    private var audioFocusRequest: AudioFocusRequest? = null

    // Bug 1: BroadcastReceiver that fires when SCO connection state changes
    private val scoReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val state = intent.getIntExtra(
                AudioManager.EXTRA_SCO_AUDIO_STATE,
                AudioManager.SCO_AUDIO_STATE_ERROR
            )
            Log.d("MainActivity", "SCO state changed: $state")
            val pending = pendingScoResult ?: return
            pendingScoResult = null
            when (state) {
                AudioManager.SCO_AUDIO_STATE_CONNECTED -> {
                    Log.d("MainActivity", "SCO connected — resolving success")
                    pending.success(null)
                }
                AudioManager.SCO_AUDIO_STATE_DISCONNECTED,
                AudioManager.SCO_AUDIO_STATE_ERROR -> {
                    Log.e("MainActivity", "SCO failed/disconnected (state=$state)")
                    pending.error("SCO_FAILED", "Bluetooth SCO failed to connect (state=$state)", null)
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // Bug 1: Register SCO receiver when Activity is visible
        val filter = IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_CHANGED)
        registerReceiver(scoReceiver, filter)
    }

    override fun onStop() {
        super.onStop()
        // Bug 1: Unregister to avoid leaks when Activity goes background
        try { unregisterReceiver(scoReceiver) } catch (_: IllegalArgumentException) {}
        // If there is a pending result when we stop, error it out so the Dart side doesn't hang
        pendingScoResult?.error("SCO_CANCELLED", "Activity stopped before SCO connected", null)
        pendingScoResult = null
    }

    override fun onDestroy() {
        super.onDestroy()
        // Bug 4: Safety net — always restore normal audio mode on destroy
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        try {
            audioManager.stopBluetoothSco()
            audioManager.isBluetoothScoOn = false
            audioManager.mode = AudioManager.MODE_NORMAL
        } catch (e: Exception) {
            Log.e("MainActivity", "onDestroy: error restoring audio state: ${e.message}")
        }
        // Bug 5: Release audio focus on destroy
        abandonAudioFocus()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel!!.setMethodCallHandler { call, result ->
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
                "getAudioInputDevices" -> {
                    try {
                        val devices = getAudioInputDevices()
                        result.success(devices)
                    } catch (e: Exception) {
                        result.error("DEVICE_ERROR", e.message, null)
                    }
                }
                "enableBluetoothSco" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    enableBluetoothSco(enable, result)
                    // result is resolved asynchronously for enable=true (Bug 1),
                    // or synchronously for enable=false
                }
                else -> result.notImplemented()
            }
        }
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

    // Bug 5: Request audio focus before starting SCO/stream
    private fun requestAudioFocus(): Boolean {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setOnAudioFocusChangeListener { focusChange ->
                    if (focusChange == AudioManager.AUDIOFOCUS_LOSS) {
                        Log.d("MainActivity", "AudioFocus lost — notifying Dart")
                        // Bug 5: Notify Dart so it can stop the stream and update UI state
                        Handler(Looper.getMainLooper()).post {
                            methodChannel?.invokeMethod("onAudioFocusLoss", null)
                        }
                    }
                }
                .build()
            audioFocusRequest = focusRequest
            val result = audioManager.requestAudioFocus(focusRequest)
            result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            val result = audioManager.requestAudioFocus(
                null,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN
            )
            result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    // Bug 5: Abandon audio focus when stopping
    private fun abandonAudioFocus() {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(null)
        }
    }

    // Bug 1: result is resolved asynchronously (enable=true) or synchronously (enable=false)
    // Bug 4: always restore MODE_NORMAL in the disable path
    // Bug 8: check BLUETOOTH_CONNECT permission on API 31+
    private fun enableBluetoothSco(enable: Boolean, result: MethodChannel.Result) {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        try {
            if (enable) {
                // Bug 8: BLUETOOTH_CONNECT is a runtime permission required on API 31+
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    if (checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT)
                        != PackageManager.PERMISSION_GRANTED
                    ) {
                        Log.e("MainActivity", "BLUETOOTH_CONNECT permission not granted")
                        result.error(
                            "PERMISSION_DENIED",
                            "BLUETOOTH_CONNECT permission is required on Android 12+",
                            null
                        )
                        return
                    }
                }

                // Bug 5: Request audio focus before starting SCO
                val focused = requestAudioFocus()
                if (!focused) {
                    Log.w("MainActivity", "Audio focus not granted — proceeding anyway")
                }

                Log.d("MainActivity", "Starting Bluetooth SCO")
                // Bug 1: Store the pending result — scoReceiver will resolve it
                pendingScoResult = result
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true
                try {
                    audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                } catch (e: SecurityException) {
                    Log.e("MainActivity", "SecurityException setting mode IN_COMMUNICATION: ${e.message}")
                }
                // Note: result is NOT resolved here — it is resolved in scoReceiver
            } else {
                Log.d("MainActivity", "Stopping Bluetooth SCO")
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
                // Bug 4: Always restore MODE_NORMAL when disabling SCO
                try {
                    audioManager.mode = AudioManager.MODE_NORMAL
                } catch (e: SecurityException) {
                    Log.e("MainActivity", "SecurityException setting mode NORMAL: ${e.message}")
                }
                // Bug 5: Release audio focus when stopping SCO
                abandonAudioFocus()
                result.success(null)
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "Error managing Bluetooth SCO: ${e.message}")
            pendingScoResult = null
            result.error("SCO_ERROR", "Error managing Bluetooth SCO: ${e.message}", null)
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
}
