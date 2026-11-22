package com.reelhouse.android.push

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.reelhouse.android.MainActivity
import com.reelhouse.android.R
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

// Push notifications from the ReelHouse server, delivered through Firebase Cloud Messaging: new
// podcast episodes, finished movie/TV downloads, sign-in alerts and the Settings test send. The
// device registers its Firebase Installation ID with POST /api/push/devices (see ReelHouseViewModel.syncPush).

// The server names one of these in android.notification.channel_id; they're created at app start
// so a message that arrives while the app is closed already has its channel to land in.
object PushChannels {
    const val NEW_EPISODES = "new_episodes"
    const val DOWNLOADS = "downloads"
    const val ACCOUNT = "account"
    const val GENERAL = "general"

    // For a message that didn't say (a data-only send): the channel its type belongs on.
    fun forType(type: String?): String = when (type) {
        PushOpen.TYPE_PODCAST -> NEW_EPISODES
        PushOpen.TYPE_DOWNLOAD -> DOWNLOADS
        PushOpen.TYPE_LOGIN -> ACCOUNT
        else -> GENERAL
    }

    fun ensure(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        fun channel(id: String, name: Int, description: Int, importance: Int) =
            NotificationChannel(id, context.getString(name), importance).apply {
                this.description = context.getString(description)
            }
        manager.createNotificationChannels(
            listOf(
                channel(NEW_EPISODES, R.string.push_channel_new_episodes_name, R.string.push_channel_new_episodes_description, NotificationManager.IMPORTANCE_DEFAULT),
                channel(DOWNLOADS, R.string.push_channel_downloads_name, R.string.push_channel_downloads_description, NotificationManager.IMPORTANCE_DEFAULT),
                // Someone signing in to the account is the one that might want acting on now.
                channel(ACCOUNT, R.string.push_channel_account_name, R.string.push_channel_account_description, NotificationManager.IMPORTANCE_HIGH),
                channel(GENERAL, R.string.push_channel_general_name, R.string.push_channel_general_description, NotificationManager.IMPORTANCE_DEFAULT),
            ),
        )
    }
}

// What a tapped notification asks to open. The extras use the FCM data keys themselves: when the
// app is in the background the system shows the notification and hands its data to MainActivity
// as extras under those names, and the notifications shown here (foreground) do the same, so
// MainActivity reads one shape either way.
data class PushOpen(
    val type: String,
    // Episode id for "podcast", library item id for "download".
    val itemId: String?,
    // Show id for "podcast".
    val podcastId: String?,
) {
    fun destination(): PushDestination = when (type) {
        TYPE_PODCAST -> when {
            itemId != null -> PushDestination.Episode(itemId, podcastId)
            podcastId != null -> PushDestination.Show(podcastId)
            else -> PushDestination.None
        }
        TYPE_DOWNLOAD -> if (itemId != null) PushDestination.MovieItem(itemId) else PushDestination.Movies
        // Sign-in alerts and the test send just open the app.
        else -> PushDestination.None
    }

    companion object {
        const val EXTRA_TYPE = "type"
        const val EXTRA_ITEM_ID = "itemId"
        const val EXTRA_PODCAST_ID = "podcastId"

        const val TYPE_PODCAST = "podcast"
        const val TYPE_DOWNLOAD = "download"
        const val TYPE_LOGIN = "login"
        const val TYPE_TEST = "test"
        private val types = setOf(TYPE_PODCAST, TYPE_DOWNLOAD, TYPE_LOGIN, TYPE_TEST)

        // Null unless this is one of ours: "type" is a generic enough extra name that an
        // unrelated intent could carry it.
        fun from(extra: (String) -> String?): PushOpen? {
            val type = extra(EXTRA_TYPE)?.takeIf { it in types } ?: return null
            return PushOpen(
                type = type,
                itemId = extra(EXTRA_ITEM_ID)?.takeIf(String::isNotBlank),
                podcastId = extra(EXTRA_PODCAST_ID)?.takeIf(String::isNotBlank),
            )
        }

        fun fromIntent(intent: Intent?): PushOpen? = intent?.let { from(it::getStringExtra) }
    }
}

sealed interface PushDestination {
    data class Episode(val episodeId: String, val showId: String?) : PushDestination
    data class Show(val showId: String) : PushDestination
    data class MovieItem(val itemId: String) : PushDestination
    data object Movies : PushDestination
    data object None : PushDestination
}

// From MainActivity to the screens: the app shell consumes this once it's showing (so after
// sign-in), navigates, and clears it. See ReelHouseApp.
object PushNavigation {
    val pending = MutableStateFlow<PushOpen?>(null)
}

// The Firebase Installation ID this install last received (what the server, and the ReelHouse
// push relay, address this phone by), so one reported while the app is closed is registered with
// the server the next time it signs in.
object PushTokenStore {
    private const val PREFERENCES = "reelhouse_push"
    private const val TOKEN_KEY = "fcm_installation_id"

    // The newest id, for a ViewModel that is alive when onRegistered fires.
    val updates = MutableStateFlow<String?>(null)

    fun save(context: Context, token: String) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putString(TOKEN_KEY, token).apply()
        updates.value = token
    }

    fun get(context: Context): String? =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(TOKEN_KEY, null)

    fun clear(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().remove(TOKEN_KEY).apply()
        updates.value = null
    }
}

object PushSupport {
    // A build without app/google-services.json has no Firebase app (the plugin that turns that
    // file into resources isn't applied - see app/build.gradle.kts). FirebaseMessaging.getInstance()
    // throws then, so everything push-related checks this first.
    fun isAvailable(context: Context): Boolean =
        runCatching { FirebaseApp.getApps(context).isNotEmpty() }.getOrDefault(false)

    // This install's Firebase Installation ID, registering with FCM first if it has none yet.
    // FCM hands the id to ReelHouseMessagingService.onRegistered rather than to the register()
    // task, so this waits (briefly) for that callback to store it. Same scheme as SentinelCore's
    // app: the server sends to it as "fid", directly or through the push relay.
    suspend fun token(context: Context): String? {
        if (!isAvailable(context)) return null
        PushTokenStore.get(context)?.takeIf { it.isNotBlank() }?.let { return it }
        suspendCancellableCoroutine { continuation ->
            FirebaseMessaging.getInstance().apply { isAutoInitEnabled = true }.register().addOnCompleteListener { task ->
                if (task.isSuccessful) {
                    continuation.resume(Unit)
                } else {
                    continuation.resumeWithException(task.exception ?: IllegalStateException("Firebase registration failed."))
                }
            }
        }
        return withTimeoutOrNull(15_000) { PushTokenStore.updates.filterNotNull().first() }
            ?: PushTokenStore.get(context)
    }
}

class ReelHouseMessagingService : FirebaseMessagingService() {
    // Firebase Messaging 25 reports the installation id here - on first registration and whenever
    // it's reissued (restore, app data cleared) - and the server has to hear about a new one or it
    // keeps sending to a dead id.
    override fun onRegistered(installationId: String) {
        PushTokenStore.save(this, installationId)
    }

    override fun onUnregistered(installationId: String) {
        PushTokenStore.clear(this)
    }

    // A message with a notification block reaches here only while the app is in the foreground
    // (in the background the system shows it itself), so it's shown here on the same channel the
    // server named. Data-only messages always arrive here.
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val open = PushOpen.from { data[it] }
        show(
            context = this,
            title = message.notification?.title ?: data["title"] ?: getString(R.string.app_name),
            body = message.notification?.body ?: data["body"].orEmpty(),
            channelId = message.notification?.channelId ?: PushChannels.forType(open?.type),
            open = open,
            fallbackKey = message.messageId,
        )
    }

    companion object {
        fun show(
            context: Context,
            title: String,
            body: String,
            channelId: String,
            open: PushOpen?,
            fallbackKey: String?,
        ) {
            PushChannels.ensure(context)
            // One per item: a second "download finished" for the same title replaces the first
            // rather than stacking, while separate messages without an item each get their own.
            val id = (open?.let { "${it.type}:${it.itemId ?: it.podcastId}" } ?: fallbackKey ?: "$title$body").hashCode()
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                open?.let {
                    putExtra(PushOpen.EXTRA_TYPE, it.type)
                    putExtra(PushOpen.EXTRA_ITEM_ID, it.itemId)
                    putExtra(PushOpen.EXTRA_PODCAST_ID, it.podcastId)
                }
            }
            // The request code differs per notification, or every pending intent would share one
            // set of extras and each tap would open whichever notification arrived last.
            val pendingIntent = PendingIntent.getActivity(
                context,
                id,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()
            try {
                NotificationManagerCompat.from(context).notify(id, notification)
            } catch (_: SecurityException) {
                // Android 13+ refuses without the notification permission; Settings says so.
            }
        }
    }
}
