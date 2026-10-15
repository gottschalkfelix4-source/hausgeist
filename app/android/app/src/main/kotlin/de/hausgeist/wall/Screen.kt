package de.hausgeist.wall

import android.app.Activity
import android.app.KeyguardManager
import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
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
 * - status -> {admin, interactive, secure, device}
 * - lockSettings: Android-Einstellungen für die Displaysperre öffnen
 * - lockPermission: App-Berechtigungen öffnen ("Auf Sperrbildschirm anzeigen" bei Xiaomi & Co.)
 * - requestAdmin / removeAdmin
 * - keepAlive: Dienst starten, der die App im Hintergrund am Leben hält
 * - off {watch}: Bildschirm aus, bei watch=true schaut die Kamera weiter nach Bewegung
 * - on: Bildschirm an
 * Richtung Dart: "motion", wenn die Kamera bei ausgeschaltetem Bildschirm jemanden sieht, und
 * "wakeCheck" {locked, resumed, interactive} kurz nach dem Aufwachen.
 */
object Screen {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private val main = Handler(Looper.getMainLooper())
    private var keyguardLock: KeyguardManager.KeyguardLock? = null

    /** Hausgeist ist im Vordergrund (von MainActivity gesetzt). */
    @Volatile var resumed = false

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
            "status" -> result.success(
                mapOf(
                    "admin" to isAdmin(ctx),
                    "interactive" to power(ctx).isInteractive,
                    // PIN, Muster oder Passwort: Dann bleibt nach dem Aufwachen der Sperrbildschirm.
                    "secure" to keyguard(ctx).isDeviceSecure,
                    "device" to "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}",
                ),
            )
            "lockPermission" -> {
                openLockPermission(a)
                result.success(null)
            }
            "lockSettings" -> {
                a.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                result.success(null)
            }
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
                keyguardLock?.reenableKeyguard()
                keyguardLock = null
                KeepAwakeService.stop(ctx)
                result.success(null)
            }
            "keepAlive" -> {
                if (isAdmin(ctx)) {
                    KeepAwakeService.start(ctx, off = false, watch = false)
                    holdKeyguardOff(ctx)
                }
                result.success(null)
            }
            "off" -> {
                if (!isAdmin(ctx)) return result.success(false)
                val watch = call.argument<Boolean>("watch") == true
                // Läuft der Dienst schon, direkt ansprechen (ein Neustart aus dem Hintergrund wäre verboten).
                val svc = KeepAwakeService.instance
                if (svc != null) svc.screenOff(watch) else KeepAwakeService.start(ctx, off = true, watch = watch)
                holdKeyguardOff(ctx)
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
        if (!power(ctx).isInteractive) {
            @Suppress("DEPRECATION")
            power(ctx).newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "hausgeist:wake",
            ).acquire(5_000)
        }
        // Hausgeist nach vorn holen, damit es über dem Sperrbildschirm liegt (singleTask: kein neues Fenster).
        activity?.let { a ->
            try {
                a.startActivity(Intent(a, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
            } catch (_: Exception) {}
        }
        // Sperrbildschirm ohne PIN gleich wegnehmen. Mehrmals versuchen, weil er sich erst nach dem
        // Einschalten aufbaut.
        for (delay in longArrayOf(150, 600, 1500)) main.postDelayed({ dismissKeyguard(ctx) }, delay)
        // Nachsehen, ob es geklappt hat; die App meldet das an den Server (Fehlersuche).
        main.postDelayed({
            channel?.invokeMethod(
                "wakeCheck",
                mapOf(
                    "locked" to keyguard(ctx).isKeyguardLocked,
                    "resumed" to resumed,
                    "interactive" to power(ctx).isInteractive,
                ),
            )
        }, 2500)
    }

    /**
     * Ohne PIN den Sperrbildschirm gar nicht erst aufbauen lassen. Die Schnittstelle ist alt und
     * wird nicht überall beachtet; dann greifen showWhenLocked und requestDismissKeyguard.
     */
    private fun holdKeyguardOff(ctx: Context) {
        val km = keyguard(ctx)
        if (km.isDeviceSecure) return
        try {
            @Suppress("DEPRECATION")
            val lock = keyguardLock ?: km.newKeyguardLock("hausgeist").also { keyguardLock = it }
            @Suppress("DEPRECATION")
            lock.disableKeyguard()
        } catch (_: Exception) {}
    }

    /** Xiaomi, Huawei & Co. verlangen eine eigene Freigabe "Auf Sperrbildschirm anzeigen". */
    private fun openLockPermission(a: Activity) {
        val pkg = a.packageName
        val miui = Intent("miui.intent.action.APP_PERM_EDITOR")
            .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
            .putExtra("extra_pkgname", pkg)
        val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
        for (i in listOf(miui, details)) {
            try {
                a.startActivity(i)
                return
            } catch (_: Exception) {}
        }
    }

    fun dismissKeyguard(ctx: Context) {
        val a = activity ?: return
        val km = keyguard(ctx)
        if (Build.VERSION.SDK_INT < 27 || !km.isKeyguardLocked) return
        a.setShowWhenLocked(true)
        a.setTurnScreenOn(true)
        if (!km.isDeviceSecure) km.requestDismissKeyguard(a, null)
    }

    fun runOnMain(block: () -> Unit) = main.post(block)

    private fun admin(ctx: Context) = ComponentName(ctx, ScreenAdmin::class.java)
    private fun policy(ctx: Context) = ctx.getSystemService(DevicePolicyManager::class.java)
    private fun power(ctx: Context) = ctx.getSystemService(PowerManager::class.java)
    private fun keyguard(ctx: Context) = ctx.getSystemService(KeyguardManager::class.java)
    fun isAdmin(ctx: Context) = policy(ctx).isAdminActive(admin(ctx))
}
