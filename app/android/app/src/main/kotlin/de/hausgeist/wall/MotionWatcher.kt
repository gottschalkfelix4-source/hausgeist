package de.hausgeist.wall

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import kotlin.math.abs

/**
 * Bewegungserkennung bei ausgeschaltetem Bildschirm, gleiche Rechnung wie motion_detector.dart:
 * Helligkeitskanal auf 32×24 Zellen verkleinern, mit dem vorigen Bild vergleichen, gleichmäßige
 * Helligkeitsänderungen herausrechnen. Zwei Bewegungsbilder innerhalb von 1,5 s wecken.
 * Bilder bleiben im Speicher und werden nie gespeichert oder gesendet.
 */
class MotionWatcher(private val ctx: Context, private val onMotion: () -> Unit) {
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var prev: FloatArray? = null
    private var startedAt = 0L
    private var lastFrame = 0L
    private val hits = ArrayDeque<Long>()

    @Volatile
    private var running = false

    @SuppressLint("MissingPermission")
    fun start() {
        if (running) return
        if (ctx.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return
        try {
            val cm = ctx.getSystemService(CameraManager::class.java)
            val id = cm.cameraIdList.firstOrNull {
                cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
            } ?: cm.cameraIdList.firstOrNull() ?: return
            val sizes = cm.getCameraCharacteristics(id)
                .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(ImageFormat.YUV_420_888) ?: return
            val size = sizes.filter { it.width >= 240 && it.height >= 180 }.minByOrNull { it.width * it.height }
                ?: sizes.minByOrNull { it.width * it.height } ?: return

            running = true
            startedAt = SystemClock.elapsedRealtime()
            val t = HandlerThread("hausgeist-motion").also { it.start() }
            val h = Handler(t.looper)
            thread = t
            handler = h
            val r = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
            r.setOnImageAvailableListener({ ir ->
                val img = try { ir.acquireLatestImage() } catch (_: Exception) { null } ?: return@setOnImageAvailableListener
                try {
                    onFrame(img)
                } finally {
                    img.close()
                }
            }, h)
            reader = r
            cm.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(d: CameraDevice) {
                    if (!running) return d.close()
                    device = d
                    @Suppress("DEPRECATION")
                    d.createCaptureSession(listOf(r.surface), object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(s: CameraCaptureSession) {
                            if (!running) return s.close()
                            session = s
                            try {
                                val req = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply { addTarget(r.surface) }
                                s.setRepeatingRequest(req.build(), null, h)
                            } catch (e: Exception) {
                                Log.w(TAG, "Kamera: $e")
                            }
                        }

                        override fun onConfigureFailed(s: CameraCaptureSession) {
                            Log.w(TAG, "Kamera: Sitzung fehlgeschlagen")
                        }
                    }, h)
                }

                override fun onDisconnected(d: CameraDevice) {
                    d.close()
                    if (device === d) device = null
                }

                override fun onError(d: CameraDevice, error: Int) {
                    Log.w(TAG, "Kamera-Fehler $error")
                    d.close()
                    if (device === d) device = null
                }
            }, h)
        } catch (e: Exception) {
            Log.w(TAG, "Kamera nicht verfügbar: $e")
            stop()
        }
    }

    fun stop() {
        running = false
        val h = handler
        val t = thread
        handler = null
        thread = null
        val close = {
            try { session?.close() } catch (_: Exception) {}
            try { device?.close() } catch (_: Exception) {}
            try { reader?.close() } catch (_: Exception) {}
            session = null
            device = null
            reader = null
            prev = null
            hits.clear()
        }
        if (h == null) return close()
        h.post(close)
        // Thread erst später beenden: Kommt die Kamera noch verspätet an, wird sie in onOpened geschlossen.
        h.postDelayed({ t?.quitSafely() }, 3_000)
    }

    private fun onFrame(img: Image) {
        if (!running) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastFrame < INTERVAL_MS) return
        lastFrame = now
        val plane = img.planes[0]
        val grid = downsample(plane.buffer, img.width, img.height, plane.rowStride, plane.pixelStride)
        val p = prev
        prev = grid
        // Kurz nach dem Ausschalten regelt die Kamera noch die Belichtung nach.
        if (p == null || now - startedAt < BLIND_MS) return
        if (changedArea(p, grid) < MIN_AREA) return
        hits.addLast(now)
        while (hits.isNotEmpty() && now - hits.first() > WINDOW_MS) hits.removeFirst()
        if (hits.size >= FRAMES_TO_WAKE) {
            running = false
            Screen.runOnMain(onMotion)
        }
    }

    private fun downsample(y: java.nio.ByteBuffer, w: Int, h: Int, stride: Int, px: Int): FloatArray {
        val out = FloatArray(GX * GY)
        val cw = w.toFloat() / GX
        val ch = h.toFloat() / GY
        val limit = y.limit()
        for (gy in 0 until GY) {
            for (gx in 0 until GX) {
                var sum = 0
                for (sy in 0 until 4) {
                    val py = (gy * ch + (sy + .5f) * ch / 4).toInt()
                    for (sx in 0 until 4) {
                        val pxx = (gx * cw + (sx + .5f) * cw / 4).toInt()
                        val i = py * stride + pxx * px
                        if (i < limit) sum += y.get(i).toInt() and 0xFF
                    }
                }
                out[gy * GX + gx] = sum / 16f
            }
        }
        return out
    }

    private fun changedArea(a: FloatArray, b: FloatArray): Float {
        var shift = 0f
        for (i in a.indices) shift += b[i] - a[i]
        shift /= a.size
        var changed = 0
        for (i in a.indices) if (abs(b[i] - a[i] - shift) > CELL_THRESHOLD) changed++
        return changed.toFloat() / a.size
    }

    companion object {
        private const val TAG = "Hausgeist"
        private const val GX = 32
        private const val GY = 24
        private const val CELL_THRESHOLD = 18f
        private const val MIN_AREA = 0.03f
        private const val INTERVAL_MS = 200L
        private const val BLIND_MS = 3_000L
        private const val WINDOW_MS = 1_500L
        private const val FRAMES_TO_WAKE = 2
    }
}
