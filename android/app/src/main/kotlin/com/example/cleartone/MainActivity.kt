package com.example.cleartone

import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaPlayer // <--- IMPORTANT: New import
import android.os.Build // <-- ADD THIS LINE
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.PI
import kotlin.math.sin

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.cleartone/audio"
    private var mediaPlayer: MediaPlayer? = null // <--- Replaced AudioTrack
    private var audioTrack: AudioTrack? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
                call,
                result ->
            when (call.method) {
                // We've changed the method name to "playFile"
                "playFile" -> {
                    val filePath = call.argument<String>("filePath")
                    val channel = call.argument<String>("channel") ?: "left"

                    if (filePath == null) {
                        result.error("INVALID_ARGUMENT", "File path cannot be null", null)
                    } else {
                        try {
                            playFile(filePath, channel)
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
                // We've changed the method name to "stopFile"
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
                else -> result.notImplemented()
            }
        }
    }

    private fun playFile(filePath: String, channel: String) {
        // Stop and release any player that might be running
        stopFile()

        mediaPlayer =
            MediaPlayer().apply {
                setDataSource(filePath)

                // This is the key part for panning
                // We must check the Android version
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    // For Android 9.0 (API 28) and newer
                    when (channel) {
                        "left" -> setVolume(1.0f, 0.0f) // Max volume left, Mute right
                        "right" -> setVolume(0.0f, 1.0f) // Mute left, Max volume right
                        else -> setVolume(1.0f, 1.0f) // Default stereo
                    }
                } else {
                    // For older Android versions, use the deprecated 'setVolume'
                    @Suppress("DEPRECATION")
                    when (channel) {
                        "left" -> setVolume(1.0f, 0.0f)
                        "right" -> setVolume(0.0f, 1.0f)
                        else -> setVolume(1.0f, 1.0f)
                    }
                }

                // Set a listener to clean up when the song is done
                setOnCompletionListener { stopFile() }

                prepare() // Prepare the file for playback
                start() // Play the file
            }
    }

    // This is the new stop function for MediaPlayer
    private fun stopFile() {
        mediaPlayer?.stop()
        mediaPlayer?.release()
        mediaPlayer = null
    }

    private fun playTone(frequency: Double, amplitudeDb: Double, channel: String, duration: Int) {
        println("playTone called with frequency: $frequency, amplitude: $amplitudeDb, channel: $channel, duration: $duration")
        val sampleRate = 44100
        val numSamples = (duration * sampleRate) / 1000
        val samples = ShortArray(numSamples * 2) // Stereo

        // Convert dB to linear amplitude (simplified)
        val amplitude = (Math.pow(10.0, amplitudeDb / 20.0) * 0.8).toFloat()

        // Generate sine wave
        for (i in 0 until numSamples) {
            val sample =
                (sin(2.0 * PI * frequency * i / sampleRate) * amplitude * Short.MAX_VALUE)
                    .toInt()
                    .toShort()

            // Stereo panning
            samples[i * 2] = if (channel == "left") sample else 0 // Left channel
            samples[i * 2 + 1] = if (channel == "right") sample else 0 // Right channel
        }

        // Create AudioTrack
        val bufferSize = samples.size * 2

        audioTrack =
            AudioTrack.Builder()
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(
                            android.media.AudioAttributes.CONTENT_TYPE_MUSIC
                        )
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
                .setTransferMode(AudioTrack.MODE_STATIC) // <-- The main fix!
                .build()

        // For MODE_STATIC, you write the data *first*, then play.
        audioTrack?.write(samples, 0, samples.size)
        audioTrack?.play()
    }

    private fun stopTone() {
        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null
    }
}
