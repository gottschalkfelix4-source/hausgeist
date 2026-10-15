package de.hausgeist.wall

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Hält die App am Leben, solange der Bildschirm aus ist: Verbindung zum Server, Aktivierungswort
 * und Bewegungserkennung laufen weiter. Android verlangt dafür eine (stille) Benachrichtigung.
 */
class KeepAwakeService : Service() {
    private var cpu: PowerManager.WakeLock? = null
    private var watcher: MotionWatcher? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!goForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.getBooleanExtra(EXTRA_OFF, false) == true) screenOff(intent.getBooleanExtra(EXTRA_WATCH, false))
        return START_NOT_STICKY
    }

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun goForeground(): Boolean {
        val nm = getSystemService(NotificationManager::class.java)
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Wandtablet", NotificationManager.IMPORTANCE_MIN))
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val n = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Hausgeist")
            .setContentText("Schaltet den Bildschirm bei Bewegung wieder ein")
            .setOngoing(true)
            .setContentIntent(
                PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE),
            )
            .build()
        return try {
            if (Build.VERSION.SDK_INT >= 30) {
                var type = 0
                if (granted(Manifest.permission.CAMERA)) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                if (granted(Manifest.permission.RECORD_AUDIO)) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (Build.VERSION.SDK_INT >= 34) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                if (type == 0) startForeground(ID, n) else startForeground(ID, n, type)
            } else {
                startForeground(ID, n)
            }
            true
        } catch (e: Exception) {
            // z. B. wenn Android den Start aus dem Hintergrund verbietet. Die App startet ihn beim
            // nächsten Öffnen erneut.
            Log.w(TAG, "Dienst nicht gestartet: $e")
            false
        }
    }

    fun screenOff(watch: Boolean) {
        if (cpu?.isHeld != true) {
            cpu = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hausgeist:off")
                .apply { acquire(12 * 60 * 60 * 1000L) }
        }
        watcher?.stop()
        watcher = if (watch) MotionWatcher(this) { Screen.motion(applicationContext) }.also { it.start() } else null
    }

    fun screenOn() {
        watcher?.stop()
        watcher = null
        cpu?.let { if (it.isHeld) it.release() }
        cpu = null
    }

    override fun onDestroy() {
        screenOn()
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "Hausgeist"
        private const val CHANNEL = "wall"
        private const val ID = 7
        private const val EXTRA_OFF = "off"
        private const val EXTRA_WATCH = "watch"

        @Volatile
        var instance: KeepAwakeService? = null
            private set

        fun start(ctx: Context, off: Boolean, watch: Boolean) {
            val i = Intent(ctx, KeepAwakeService::class.java).putExtra(EXTRA_OFF, off).putExtra(EXTRA_WATCH, watch)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Exception) {
                Log.w(TAG, "Dienst nicht gestartet: $e")
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, KeepAwakeService::class.java))
        }
    }
}
