package de.hausgeist.wall

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Wandtablet: Nach dem Aufwecken gleich die App zeigen, nicht den Sperrbildschirm.
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Screen.attach(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onResume() {
        super.onResume()
        Screen.resumed = true
        // Wischen-Sperre (ohne PIN) gleich mit entfernen, damit nach dem Aufwachen alles bedienbar ist.
        Screen.dismissKeyguard(applicationContext)
    }

    override fun onPause() {
        Screen.resumed = false
        super.onPause()
    }

    override fun onDestroy() {
        Screen.detach(this)
        super.onDestroy()
    }
}
