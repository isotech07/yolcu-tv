package com.yolcutv.yolcu_tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Surface
import android.view.WindowManager
import io.flutter.plugin.common.EventChannel

/**
 * Telefon ekranını yakalar ve donanım H.264 kodlayıcısıyla sıkıştırır.
 *
 * Akış:  Ekran → VirtualDisplay → MediaCodec (H.264) → Flutter (EventChannel)
 *        → yerel web sunucusu → araç tarayıcısı (jmuxer + MSE)
 *
 * Kodlama donanımda yapıldığı için işlemci yükü ve ısınma düşüktür.
 * Her paket: [1 bayt anahtar kare bayrağı][8 bayt zaman damgası µs][H.264 Annex-B veri]
 */
class ScreenCaptureService : Service() {

    companion object {
        const val ACTION_STOP = "com.yolcutv.STOP_MIRROR"
        private const val CHANNEL_ID = "yolcutv_mirror"
        private const val NOTIFICATION_ID = 7301

        @Volatile
        var running = false
            private set

        @Volatile
        var sink: EventChannel.EventSink? = null

        @Volatile
        var instance: ScreenCaptureService? = null
            private set
    }

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null

    @Volatile private var codec: MediaCodec? = null
    @Volatile private var csd: ByteArray? = null // SPS + PPS
    @Volatile private var stopping = false

    private var maxSize = 1280
    private var bitrate = 4_000_000
    private var fps = 30
    private var width = 0
    private var height = 0
    private var dpi = 320

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || intent.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY

        maxSize = intent.getIntExtra("maxSize", 1280)
        bitrate = intent.getIntExtra("bitrate", 4_000_000)
        fps = intent.getIntExtra("fps", 30)
        val resultCode = intent.getIntExtra("resultCode", 0)
        val data = projectionData(intent)

        // Android 10+ : getMediaProjection çağrılmadan önce ön plan servisi başlamış olmalı.
        startAsForeground()

        try {
            if (data == null) throw IllegalStateException("İzin verisi eksik")
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val p = mpm.getMediaProjection(resultCode, data)
                ?: throw IllegalStateException("Ekran yakalama başlatılamadı")
            projection = p
            // Android 14+: sanal ekran oluşturulmadan önce geri çağrı kaydı zorunlu.
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    stopSelf()
                }
            }, main)

            computeSize()
            val (c, surface) = createEncoder()
            display = p.createVirtualDisplay(
                "YolcuTV",
                width, height, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                surface, null, null
            )
            activate(c)
            running = true
            instance = this
            post("started")
        } catch (e: Exception) {
            post("error:${e.message ?: e.javaClass.simpleName}")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    /** Telefon döndürüldüğünde görüntüyü yeni yöne göre yeniden kurar. */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (!running) return
        val oldW = width
        val oldH = height
        computeSize()
        if (width == oldW && height == oldH) return
        val d = display ?: return
        try {
            val (c, surface) = createEncoder()
            d.resize(width, height, dpi)
            d.surface = surface
            post("reset") // tarayıcı çözücüsünü yeni çözünürlük için sıfırlasın
            activate(c) // eski kodlayıcının döngüsü kendiliğinden kapanır
        } catch (e: Exception) {
            post("error:${e.message ?: e.javaClass.simpleName}")
        }
    }

    fun requestKeyFrame() {
        val c = codec ?: return
        try {
            c.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
        } catch (e: Exception) {
            // kodlayıcı kapanıyor olabilir
        }
    }

    override fun onDestroy() {
        stopping = true
        running = false
        instance = null
        try {
            display?.release()
        } catch (e: Exception) {
        }
        display = null
        try {
            projection?.stop()
        } catch (e: Exception) {
        }
        projection = null
        codec = null
        post("stopped")
        super.onDestroy()
    }

    // ---------------------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun projectionData(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra("data", Intent::class.java)
        else intent.getParcelableExtra("data")

    @Suppress("DEPRECATION")
    private fun computeSize() {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val dm = DisplayMetrics()
        wm.defaultDisplay.getRealMetrics(dm)
        val w = dm.widthPixels
        val h = dm.heightPixels
        val scale = minOf(1f, maxSize.toFloat() / maxOf(w, h))
        width = align16((w * scale).toInt())
        height = align16((h * scale).toInt())
        dpi = dm.densityDpi
    }

    // Kodlayıcıların çoğu 16'nın katı boyutlarla en sorunsuz çalışır.
    private fun align16(v: Int) = maxOf(16, v / 16 * 16)

    private fun createEncoder(): Pair<MediaCodec, Surface> {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            // Ekran değişmese de saniyede en az 10 kare üret: yeni bağlanan ekran hemen görüntü alır.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
            if (Build.VERSION.SDK_INT >= 23) setInteger(MediaFormat.KEY_PRIORITY, 0) // gerçek zamanlı
            if (Build.VERSION.SDK_INT >= 29) setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0) // düşük gecikme
        }
        val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = c.createInputSurface()
        c.start()
        return c to surface
    }

    private fun activate(c: MediaCodec) {
        csd = null
        codec = c
        Thread({ drain(c) }, "yolcutv-encoder").start()
    }

    private fun drain(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (!stopping && codec === c) {
                val index = c.dequeueOutputBuffer(info, 20_000)
                if (index < 0) continue
                val buf = c.getOutputBuffer(index)
                if (buf != null && info.size > 0) {
                    val bytes = ByteArray(info.size)
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    buf.get(bytes)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        csd = bytes
                    } else {
                        val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        val config = csd
                        // Anahtar karelerin önüne SPS/PPS eklenir; yeni bağlanan ekran buradan başlar.
                        emit(if (key && config != null) config + bytes else bytes, key, info.presentationTimeUs)
                    }
                }
                c.releaseOutputBuffer(index, false)
            }
        } catch (e: Exception) {
            // durdurma sırasında normal
        } finally {
            try {
                c.stop()
            } catch (e: Exception) {
            }
            c.release()
        }
    }

    private fun emit(data: ByteArray, key: Boolean, ptsUs: Long) {
        val out = ByteArray(9 + data.size)
        out[0] = (if (key) 1 else 0).toByte()
        for (i in 0 until 8) {
            out[1 + i] = (ptsUs shr (56 - 8 * i)).toByte()
        }
        System.arraycopy(data, 0, out, 9, data.size)
        main.post { sink?.success(out) }
    }

    private fun post(message: String) {
        main.post { sink?.success(message) }
    }

    @Suppress("DEPRECATION")
    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Ekran yansıtma", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val stopIntent = PendingIntent.getService(
            this, 1,
            Intent(this, ScreenCaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 2, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else Notification.Builder(this)
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Ekran araca yansıtılıyor")
            .setContentText("Durdurmak için Durdur'a dokunun")
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_media_pause, "Durdur", stopIntent)
            .build()

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}
