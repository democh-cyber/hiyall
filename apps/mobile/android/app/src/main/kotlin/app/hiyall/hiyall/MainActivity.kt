package app.hiyall.hiyall

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createDefaultNotificationChannel()
    }

    // The channel the server names in every push (AndroidChannel in services/api/internal/push)
    // and the manifest names as the default. Android 8+ needs it to exist before a notification
    // arrives while the app is closed.
    private fun createDefaultNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            "hiyall_default",
            "Messages and activity",
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.description = "New messages, friend requests and followers"
        manager.createNotificationChannel(channel)
    }
}
