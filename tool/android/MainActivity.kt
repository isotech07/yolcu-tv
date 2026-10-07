package com.yolcutv.yolcu_tv

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val captureRequest = 7302
    private var pending: MethodChannel.Result? = null
    private var options: Map<*, *>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "yolcutv/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> startCapture(call.arguments as? Map<*, *>, result)
                "stop" -> {
                    stopService(Intent(this, ScreenCaptureService::class.java))
                    result.success(true)
                }
                "isRunning" -> result.success(ScreenCaptureService.running)
                "requestKeyFrame" -> {
                    ScreenCaptureService.instance?.requestKeyFrame()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "yolcutv/screen/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    ScreenCaptureService.sink = events
                }

                override fun onCancel(arguments: Any?) {
                    ScreenCaptureService.sink = null
                }
            }
        )
    }

    private fun startCapture(args: Map<*, *>?, result: MethodChannel.Result) {
        if (ScreenCaptureService.running) {
            result.success(true)
            return
        }
        if (pending != null) {
            result.error("busy", "İzin penceresi zaten açık", null)
            return
        }
        pending = result
        options = args
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(mpm.createScreenCaptureIntent(), captureRequest)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != captureRequest) return
        val result = pending
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result?.success(false) // kullanıcı izin vermedi
            return
        }
        val intent = Intent(this, ScreenCaptureService::class.java)
            .putExtra("resultCode", resultCode)
            .putExtra("data", data)
            .putExtra("maxSize", (options?.get("maxSize") as? Number)?.toInt() ?: 1280)
            .putExtra("bitrate", (options?.get("bitrate") as? Number)?.toInt() ?: 4_000_000)
            .putExtra("fps", (options?.get("fps") as? Number)?.toInt() ?: 30)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
        result?.success(true)
    }
}
