package com.hana.hana_app

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.view.WindowManager
import android.os.Bundle
import android.os.SystemClock
import androidx.core.content.ContextCompat
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val microphoneRequestCode = 6102
    private var recorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var recordingStartedAt: Long = 0
    private var pendingClientId: String? = null
    private var pendingStartResult: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != microphoneRequestCode) return
        val result = pendingStartResult
        val clientId = pendingClientId
        pendingStartResult = null
        pendingClientId = null
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED ||
            result == null || clientId == null
        ) {
            result?.success(false)
        } else {
            startRecorder(clientId, result)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        clearPrivateRuntime()
        super.onCreate(savedInstanceState)
    }

    private fun clearPrivateRuntime() {
        val directory = File(cacheDir, "prv_rt")
        if (directory.canonicalFile.parentFile == cacheDir.canonicalFile) {
            directory.deleteRecursively()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hana/secure_window"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "clearPrivateRuntime" -> {
                    clearPrivateRuntime()
                    result.success(null)
                }
                "setSecure" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hana/voice_recorder"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val clientId = call.argument<String>("clientId")
                    if (clientId == null || !clientId.matches(Regex("^[a-fA-F0-9-]{36}$"))) {
                        result.error("AUDIO_INVALID", "Invalid client id", null)
                    } else if (ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.RECORD_AUDIO
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        if (pendingStartResult != null) {
                            result.error("AUDIO_BUSY", "Microphone permission pending", null)
                        } else {
                            pendingClientId = clientId
                            pendingStartResult = result
                            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), microphoneRequestCode)
                        }
                    } else {
                        startRecorder(clientId, result)
                    }
                }
                "stop" -> stopRecorder(result)
                "cancel" -> {
                    cancelRecorder()
                    result.success(null)
                }
                "delete" -> {
                    val path = call.argument<String>("path")
                    if (path != null) deleteVoiceFile(path)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun newRecorder(): MediaRecorder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this) else MediaRecorder()

    private fun startRecorder(clientId: String, result: MethodChannel.Result) {
        if (recorder != null) {
            result.error("AUDIO_BUSY", "A recording is already active", null)
            return
        }
        val directory = File(cacheDir, "voice")
        directory.mkdirs()
        val file = File(directory, "$clientId.m4a")
        try {
            val next = newRecorder().apply {
                setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioSamplingRate(16000)
                setAudioChannels(1)
                setAudioEncodingBitRate(48000)
                setOutputFile(file.absolutePath)
                prepare()
                start()
            }
            recorder = next
            recordingFile = file
            recordingStartedAt = SystemClock.elapsedRealtime()
            result.success(true)
        } catch (error: Exception) {
            recorder?.release()
            recorder = null
            file.delete()
            result.error("AUDIO_START_FAILED", error.javaClass.simpleName, null)
        }
    }

    private fun stopRecorder(result: MethodChannel.Result) {
        val active = recorder
        val file = recordingFile
        if (active == null || file == null) {
            result.success(null)
            return
        }
        val duration = (SystemClock.elapsedRealtime() - recordingStartedAt).toInt()
        try {
            active.stop()
            active.release()
            recorder = null
            recordingFile = null
            result.success(mapOf("path" to file.absolutePath, "durationMs" to duration))
        } catch (error: Exception) {
            active.release()
            recorder = null
            recordingFile = null
            file.delete()
            result.error("AUDIO_STOP_FAILED", error.javaClass.simpleName, null)
        }
    }

    private fun cancelRecorder() {
        val active = recorder
        recorder = null
        try {
            active?.stop()
        } catch (_: Exception) {
        } finally {
            active?.release()
        }
        recordingFile?.delete()
        recordingFile = null
    }

    private fun deleteVoiceFile(path: String) {
        val root = File(cacheDir, "voice").canonicalFile
        val file = File(path).canonicalFile
        if (file.parentFile == root) file.delete()
    }

    override fun onPause() {
        cancelRecorder()
        super.onPause()
    }
}
