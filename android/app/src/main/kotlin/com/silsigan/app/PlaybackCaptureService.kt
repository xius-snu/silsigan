package com.silsigan.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Foreground service that holds a MediaProjection token and streams other
 * apps' playback through AudioPlaybackCapture (API 29+). Dart polls PCM16 /
 * 24 kHz / mono via readLoopback. DRM and USAGE_VOICE_COMMUNICATION sources
 * are not capturable and stay silent.
 */
class PlaybackCaptureService : Service() {

    companion object {
        const val ACTION_START = "com.silsigan.app.playback.START"
        const val ACTION_STOP = "com.silsigan.app.playback.STOP"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        const val SAMPLE_RATE = 24000
        private const val FALLBACK_RATE = 48000
        private const val CHANNEL_ID = "silsigan_playback_capture"
        private const val NOTIFICATION_ID = 257
        private const val MAX_PENDING_BYTES = SAMPLE_RATE * 2 * 2

        private val pendingLock = Any()
        private val pending = java.io.ByteArrayOutputStream()

        @Volatile
        var isCapturing: Boolean = false
            private set

        @Volatile
        var lastError: String? = null

        fun takePending(): ByteArray {
            synchronized(pendingLock) {
                if (pending.size() == 0) return ByteArray(0)
                val bytes = pending.toByteArray()
                pending.reset()
                return bytes
            }
        }

        fun appendPcm(data: ByteArray, offset: Int, length: Int) {
            if (length <= 0) return
            synchronized(pendingLock) {
                pending.write(data, offset, length)
                if (pending.size() > MAX_PENDING_BYTES) {
                    val all = pending.toByteArray()
                    pending.reset()
                    pending.write(all, all.size - MAX_PENDING_BYTES, MAX_PENDING_BYTES)
                }
            }
        }

        fun markCapturing(value: Boolean) {
            isCapturing = value
        }

        fun setError(message: String?) {
            lastError = message
        }

        fun clearPending() {
            synchronized(pendingLock) { pending.reset() }
        }
    }

    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var captureThread: Thread? = null
    @Volatile private var running = false
    private var captureRate = SAMPLE_RATE

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            stopInternal()
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopInternal()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                startAsForeground()
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
                val data = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_RESULT_DATA)
                }
                if (resultCode == 0 || data == null) {
                    setError("Screen-audio permission was not granted")
                    DesktopAudioCapture.notifyStartFinished(false, lastError)
                    stopInternal()
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (!startProjection(resultCode, data)) {
                    stopInternal()
                    stopSelf()
                    return START_NOT_STICKY
                }
                return START_STICKY
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopInternal()
        super.onDestroy()
    }

    private fun startAsForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startProjection(resultCode: Int, data: Intent): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            setError("Speaker capture requires Android 10 or later")
            DesktopAudioCapture.notifyStartFinished(false, lastError)
            return false
        }
        setError(null)
        clearPending()
        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = try {
            mgr.getMediaProjection(resultCode, data)
        } catch (e: Exception) {
            setError("Could not start screen-audio capture: ${e.message}")
            DesktopAudioCapture.notifyStartFinished(false, lastError)
            return false
        }
        if (projection == null) {
            setError("Could not start screen-audio capture")
            DesktopAudioCapture.notifyStartFinished(false, lastError)
            return false
        }
        projection.registerCallback(projectionCallback, Handler(Looper.getMainLooper()))
        mediaProjection = projection
        try {
            virtualDisplay = projection.createVirtualDisplay(
                "silsigan-audio",
                16,
                16,
                1,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                null,
                null,
                null,
            )
        } catch (_: Exception) {
        }
        val record = buildAudioRecord(projection) ?: run {
            setError("Could not open playback capture")
            DesktopAudioCapture.notifyStartFinished(false, lastError)
            return false
        }
        audioRecord = record
        try {
            record.startRecording()
        } catch (e: Exception) {
            setError("Playback capture failed to start: ${e.message}")
            DesktopAudioCapture.notifyStartFinished(false, lastError)
            return false
        }
        running = true
        markCapturing(true)
        captureThread = Thread({ captureLoop(record) }, "silsigan-playback-capture").also {
            it.isDaemon = true
            it.start()
        }
        DesktopAudioCapture.notifyStartFinished(true, null)
        return true
    }

    private fun buildAudioRecord(projection: MediaProjection): AudioRecord? {
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        fun tryRate(rate: Int): AudioRecord? {
            val minBuf = AudioRecord.getMinBufferSize(
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuf <= 0) return null
            return try {
                AudioRecord.Builder()
                    .setAudioPlaybackCaptureConfig(config)
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(rate)
                            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                            .build(),
                    )
                    .setBufferSizeInBytes(minBuf * 4)
                    .build()
            } catch (_: Exception) {
                null
            }?.takeIf { it.state == AudioRecord.STATE_INITIALIZED }
        }

        tryRate(SAMPLE_RATE)?.let {
            captureRate = SAMPLE_RATE
            return it
        }
        tryRate(FALLBACK_RATE)?.let {
            captureRate = FALLBACK_RATE
            return it
        }
        return null
    }

    private fun captureLoop(record: AudioRecord) {
        val buf = ByteArray(record.bufferSizeInFrames.coerceAtLeast(1024) * 2)
        while (running) {
            val n = try {
                record.read(buf, 0, buf.size)
            } catch (_: Exception) {
                break
            }
            if (n <= 0) continue
            if (captureRate == FALLBACK_RATE) {
                val outLen = (n / 4) * 2
                if (outLen <= 0) continue
                val down = ByteArray(outLen)
                var o = 0
                var i = 0
                while (i + 3 < n) {
                    down[o++] = buf[i]
                    down[o++] = buf[i + 1]
                    i += 4
                }
                appendPcm(down, 0, o)
            } else {
                appendPcm(buf, 0, n)
            }
        }
    }

    private fun stopInternal() {
        running = false
        markCapturing(false)
        try { captureThread?.join(500) } catch (_: Exception) {}
        captureThread = null
        try { audioRecord?.stop() } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
        try { virtualDisplay?.release() } catch (_: Exception) {}
        virtualDisplay = null
        val projection = mediaProjection
        mediaProjection = null
        if (projection != null) {
            try { projection.unregisterCallback(projectionCallback) } catch (_: Exception) {}
            try { projection.stop() } catch (_: Exception) {}
        }
        clearPending()
        try { stopForeground(STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Screen audio",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Captures audio playing on this device"
        channel.setSound(null, null)
        mgr.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Silsigan")
            .setContentText("Capturing screen audio")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
