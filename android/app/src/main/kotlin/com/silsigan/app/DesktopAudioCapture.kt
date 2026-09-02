package com.silsigan.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `com.silsigan.app/desktop_audio` for Android playback
 * capture. Matches Windows/macOS: listDevices, startLoopback, stopLoopback,
 * readLoopback. startLoopback shows the system MediaProjection sheet.
 */
object DesktopAudioCapture : MethodChannel.MethodCallHandler {
    private const val CHANNEL = "com.silsigan.app/desktop_audio"
    private const val REQUEST_PROJECTION = 0x51A1
    private const val SYSTEM_ID = "system"
    private const val SYSTEM_LABEL = "System / screen audio"
    private const val STOP_GRACE_MS = 1500L

    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var pendingStart: MethodChannel.Result? = null
    private var stopRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var waitingForConsent = false

    fun register(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        channel?.setMethodCallHandler(null)
        val ch = MethodChannel(messenger, CHANNEL)
        ch.setMethodCallHandler(this)
        channel = ch
    }

    fun unregister() {
        waitingForConsent = false
        notifyStartFinished(false, "Screen-audio permission was not granted")
        channel?.setMethodCallHandler(null)
        channel = null
        activity = null
        pendingStart = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(listDevices())
            "startLoopback" -> startLoopback(result)
            "stopLoopback" -> {
                scheduleStop()
                result.success(null)
            }
            "readLoopback" -> result.success(PlaybackCaptureService.takePending())
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PROJECTION) return false
        waitingForConsent = false
        val act = activity
        if (act == null) {
            notifyStartFinished(false, "Activity unavailable")
            return true
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            notifyStartFinished(false, "Screen-audio permission was not granted")
            return true
        }
        if (pendingStart == null) {
            return true
        }
        val intent = Intent(act, PlaybackCaptureService::class.java).apply {
            action = PlaybackCaptureService.ACTION_START
            putExtra(PlaybackCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(PlaybackCaptureService.EXTRA_RESULT_DATA, data)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                act.startForegroundService(intent)
            } else {
                act.startService(intent)
            }
        } catch (e: Exception) {
            notifyStartFinished(false, "Could not start capture service: ${e.message}")
        }
        return true
    }

    fun notifyStartFinished(ok: Boolean, error: String?) {
        val pending = pendingStart
        pendingStart = null
        if (pending == null) return
        mainHandler.post {
            if (ok) {
                pending.success(null)
            } else {
                val blob = (error ?: "").lowercase()
                val cancelled = blob.contains("not granted") ||
                    blob.contains("permission") ||
                    blob.contains("cancel")
                pending.error(
                    if (cancelled) "CANCELLED" else "CAPTURE",
                    error ?: "Speaker capture failed",
                    null,
                )
            }
        }
    }

    private fun listDevices(): Map<String, Any> {
        val outputs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            listOf(
                mapOf(
                    "id" to SYSTEM_ID,
                    "label" to SYSTEM_LABEL,
                    "isDefault" to true,
                ),
            )
        } else {
            emptyList()
        }
        return mapOf(
            "inputs" to emptyList<Any>(),
            "outputs" to outputs,
        )
    }

    private fun startLoopback(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Speaker capture requires Android 10 or later", null)
            return
        }
        cancelScheduledStop()
        if (PlaybackCaptureService.isCapturing) {
            result.success(null)
            return
        }
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "No activity to request screen audio", null)
            return
        }
        if (pendingStart != null || waitingForConsent) {
            result.error("BUSY", "Screen-audio permission is already showing", null)
            return
        }
        val mgr = act.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingStart = result
        waitingForConsent = true
        try {
            // API 34+: default the picker to the entire screen, not a single
            // app. ReplayKit on iOS has no equivalent, so this is Android-only.
            val intent = createCaptureIntent(mgr)
            act.startActivityForResult(intent, REQUEST_PROJECTION)
        } catch (e: Exception) {
            waitingForConsent = false
            pendingStart = null
            result.error("CAPTURE", "Could not show capture permission: ${e.message}", null)
        }
    }

    @Suppress("NewApi")
    private fun createCaptureIntent(mgr: MediaProjectionManager): Intent {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            try {
                return mgr.createScreenCaptureIntent(
                    MediaProjectionConfig.createConfigForDefaultDisplay(),
                )
            } catch (_: Exception) {
                // Some OEM builds reject the config form; fall through.
            }
        }
        return mgr.createScreenCaptureIntent()
    }

    private fun scheduleStop() {
        cancelScheduledStop()
        val work = Runnable { actuallyStop() }
        stopRunnable = work
        mainHandler.postDelayed(work, STOP_GRACE_MS)
    }

    private fun cancelScheduledStop() {
        stopRunnable?.let { mainHandler.removeCallbacks(it) }
        stopRunnable = null
    }

    private fun actuallyStop() {
        stopRunnable = null
        val act = activity ?: return
        val intent = Intent(act, PlaybackCaptureService::class.java).apply {
            action = PlaybackCaptureService.ACTION_STOP
        }
        try {
            act.startService(intent)
        } catch (_: Exception) {
        }
    }
}
