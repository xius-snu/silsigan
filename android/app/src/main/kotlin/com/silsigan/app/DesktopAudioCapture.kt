package com.silsigan.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
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
        CaptureAudioRoute.unregister()
        channel?.setMethodCallHandler(null)
        channel = null
        activity = null
        pendingStart = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(listDevices())
            "applyCaptureRoute" -> {
                CaptureAudioRoute.apply(activity, call.arguments as? Map<*, *>)
                result.success(null)
            }
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
            "inputs" to CaptureAudioRoute.listInputs(activity),
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

/// Split audio route: capture stays on the selected (usually built-in) mic
/// while media / TTS can play through Bluetooth A2DP headphones. SCO/HFP is
/// only started when the user explicitly picks a Bluetooth microphone.
private object CaptureAudioRoute {
    private var preferredMicId: String? = null
    private var wantBtMic = false
    private var applied = false
    private var applying = false
    private var callback: AudioDeviceCallback? = null
    private var registeredManager: AudioManager? = null
    private var activityRef: java.lang.ref.WeakReference<Activity>? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun apply(activity: Activity?, args: Map<*, *>?) {
        val act = activity ?: return
        activityRef = java.lang.ref.WeakReference(act)
        if (args != null) {
            if (args.containsKey("micDeviceId")) {
                val id = args["micDeviceId"] as? String
                preferredMicId = if (id.isNullOrEmpty()) null else id
            }
            val bluetoothMic = args["bluetoothMic"]
            if (bluetoothMic is Boolean) {
                wantBtMic = bluetoothMic && !preferredMicId.isNullOrEmpty()
            }
        }
        if (preferredMicId == null) wantBtMic = false
        applied = true
        applyNow(act)
        register(act)
    }

    fun unregister() {
        val am = registeredManager
        val cb = callback
        if (am != null && cb != null) {
            try {
                am.unregisterAudioDeviceCallback(cb)
            } catch (_: Exception) {
            }
        }
        registeredManager = null
        callback = null
        activityRef = null
        applied = false
    }

    fun listInputs(activity: Activity?): List<Map<String, Any>> {
        val act = activity ?: return emptyList()
        val am = act.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        var seenBuiltin = false
        return am.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .filter { keepInput(it) }
            .map { info ->
                val builtin = info.type == AudioDeviceInfo.TYPE_BUILTIN_MIC
                val isDefault = builtin && !seenBuiltin
                if (builtin) seenBuiltin = true
                mapOf(
                    "id" to info.id.toString(),
                    "label" to inputLabel(info),
                    "isDefault" to isDefault,
                    "isBluetooth" to isBluetoothType(info.type),
                )
            }
    }

    @Suppress("DEPRECATION")
    private fun applyNow(activity: Activity) {
        if (applying) return
        applying = true
        try {
            val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (wantBtMic) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val sco = am.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                            it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
                    }
                    if (sco != null) {
                        am.setCommunicationDevice(sco)
                    } else {
                        am.mode = AudioManager.MODE_IN_COMMUNICATION
                        am.startBluetoothSco()
                        am.isBluetoothScoOn = true
                    }
                } else {
                    am.mode = AudioManager.MODE_IN_COMMUNICATION
                    am.startBluetoothSco()
                    am.isBluetoothScoOn = true
                }
            } else {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    am.clearCommunicationDevice()
                }
                if (am.isBluetoothScoOn) {
                    am.stopBluetoothSco()
                    am.isBluetoothScoOn = false
                }
                am.mode = AudioManager.MODE_NORMAL
            }
        } catch (_: Exception) {
        } finally {
            applying = false
        }
    }

    private fun register(activity: Activity) {
        if (callback != null) return
        val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                reapply()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                reapply()
            }
        }
        am.registerAudioDeviceCallback(cb, mainHandler)
        callback = cb
        registeredManager = am
    }

    private fun reapply() {
        if (!applied) return
        val act = activityRef?.get() ?: return
        mainHandler.post { applyNow(act) }
    }

    private fun keepInput(info: AudioDeviceInfo): Boolean {
        if (!info.isSource) return false
        return when (info.type) {
            AudioDeviceInfo.TYPE_TELEPHONY,
            AudioDeviceInfo.TYPE_REMOTE_SUBMIX,
            28, // TYPE_ECHO_REFERENCE
            -> false
            else -> true
        }
    }

    private fun isBluetoothType(type: Int): Boolean {
        return type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
            type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
            type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
    }

    private fun inputLabel(info: AudioDeviceInfo): String {
        val name = info.productName?.toString()?.trim().orEmpty()
        if (info.type == AudioDeviceInfo.TYPE_BUILTIN_MIC) {
            return name.ifEmpty { "Phone microphone" }
        }
        if (name.isNotEmpty()) return name
        return "Microphone ${info.id}"
    }
}
