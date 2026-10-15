package de.hausgeist.wall

import android.app.Activity
import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Nötig, damit die App den Bildschirm wirklich ausschalten darf (Geräteverwaltung, nur "Sperren"). */
class ScreenAdmin : DeviceAdminReceiver()

/**
 * Echtes Ausschalten des Bildschirms und Aufwecken. Ohne Geräteverwaltung kann eine App die
 * Hintergrundbeleuchtung nicht abschalten, nur dunkel stellen.
 *
 * Kanal "hausgeist/screen":
 * - status -> {admin, interactive}
 * - requestAdmin / removeAdmin
 * - keepAlive: Dienst starten, der die App im Hintergrund am Leben hält
 * - off {watch}: Bildschirm aus, bei watch=true schaut die Kamera weiter nach Bewegung
 * - on: Bildschirm an
 * Richtung Dart: "motion", wenn die Kamera bei ausgeschaltetem Bildschirm jemanden sieht.
 */
object Screen {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private val main = Handler(Looper.getMainLooper())

    fun attach(a: Activity, messenger: BinaryMessenger) {
        activity = a
        channel = MethodChannel(messenger, "hausgeist/screen").also { ch ->
            ch.setMethodCallHandler { call, result ->
                try {
                    handle(a, call, result)
                } catch (e: Exception) {
                    result.error("screen", e.message, null)
                }
            }
        }
    }

    fun detach(a: Activity) {
        if (activity !== a) return
        channel?.setMethodCallHandler(null)
        channel = null
        activity = null
    }

    private fun handle(a: Activity, call: MethodCall, result: MethodChannel.Result) {
        val ctx = a.applicationContext
        when (call.method) {
            "status" -> result.success(mapOf("admin" to isAdmin(ctx), "interactive" to power(ctx).isInteractive))
            "requestAdmin" -> {
                a.startActivity(
                    Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                        .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin(ctx))
                        .putExtra(
                            DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                            "Damit Hausgeist den Bildschirm ganz ausschalten kann, wenn niemand im Raum ist. " +
                                "Bei Bewegung geht er wieder an. Die App nutzt nur das Sperren des Bildschirms.",
                        ),
                )
                result.success(null)
            }
            "removeAdmin" -> {
                if (isAdmin(ctx)) policy(ctx).removeActiveAdmin(admin(ctx))
                KeepAwakeService.stop(ctx)
                result.success(null)
            }
            "keepAlive" -> {
                if (isAdmin(ctx)) KeepAwakeService.start(ctx, off = false, watch = false)
                result.success(null)
            }
            "off" -> {
                if (!isAdmin(ctx)) return result.success(false)
                val watch = call.argument<Boolean>("watch") == true
                // Läuft der Dienst schon, direkt ansprechen (ein Neustart aus dem Hintergrund wäre verboten).
                val svc = KeepAwakeService.instance
                if (svc != null) svc.screenOff(watch) else KeepAwakeService.start(ctx, off = true, watch = watch)
                policy(ctx).lockNow()
                result.success(true)
            }
            "on" -> {
                on(ctx)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Kamera hat bei ausgeschaltetem Bildschirm Bewegung gesehen. */
    fun motion(ctx: Context) {
        on(ctx)
        channel?.invokeMethod("motion", null)
    }

    private fun on(ctx: Context) {
        KeepAwakeService.instance?.screenOn()
        if (power(ctx).isInteractive) return
        @Suppress("DEPRECATION")
        power(ctx).newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
            "hausgeist:wake",
        ).acquire(5_000)
    }

    fun runOnMain(block: () -> Unit) = main.post(block)

    private fun admin(ctx: Context) = ComponentName(ctx, ScreenAdmin::class.java)
    private fun policy(ctx: Context) = ctx.getSystemService(DevicePolicyManager::class.java)
    private fun power(ctx: Context) = ctx.getSystemService(PowerManager::class.java)
    fun isAdmin(ctx: Context) = policy(ctx).isAdminActive(admin(ctx))
}
