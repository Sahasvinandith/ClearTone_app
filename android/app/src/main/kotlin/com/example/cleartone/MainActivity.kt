package com.example.cleartone

import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaPlayer
import android.os.Build
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                else -> result.notImplemented()
            }
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
