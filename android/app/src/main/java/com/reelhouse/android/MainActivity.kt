package com.reelhouse.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.viewmodel.compose.viewModel
import com.reelhouse.android.audio.AudioRuntime
import com.reelhouse.android.push.PushChannels
import com.reelhouse.android.push.PushNavigation
import com.reelhouse.android.push.PushOpen
import com.reelhouse.android.ui.ReelHouseApp
import com.reelhouse.android.ui.ReelHouseViewModel
import com.reelhouse.android.ui.audio.AudioNavigation
import com.reelhouse.android.ui.theme.ReelHouseTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        // .auto() picks light/dark icon contrast itself from the current configuration, so it
        // stays correct whichever theme ReelHouseTheme resolves to (system setting or dynamic
        // color) instead of hardcoding dark-style icons regardless of appearance.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
        )
        // Before any push can arrive: the server addresses its messages to these channels.
        PushChannels.ensure(this)
        handleIntent(intent)
        // Only on a fresh start: a rotation recreates the activity with the same intent, and a
        // voice search must not start playing twice, nor a tapped notification navigate twice.
        if (savedInstanceState == null) {
            handleMediaSearch(intent)
            handlePushIntent(intent)
        }
        setContent {
            ReelHouseTheme {
                val model: ReelHouseViewModel = viewModel()
                ReelHouseApp(model)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
        handleMediaSearch(intent)
        handlePushIntent(intent)
    }

    // A tapped push notification (see push/PushNotifications): the app shell opens what it names
    // once it's showing, which is after sign-in when one is needed.
    private fun handlePushIntent(intent: Intent?) {
        PushOpen.fromIntent(intent)?.let { PushNavigation.pending.value = it }
    }

    // "Play Rumours on ReelHouse" - the voice search every media app must accept.
    private fun handleMediaSearch(intent: Intent?) {
        if (intent?.action != android.provider.MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH) return
        AudioRuntime.get(this).playFromSearch(intent.getStringExtra(android.app.SearchManager.QUERY).orEmpty())
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(NowPlayingExtra, false) == true) AudioNavigation.openNowPlaying.value = true
    }

    companion object {
        // The media notification: opens Now Playing (see audio/AudioPlaybackService).
        const val NowPlayingExtra = "nowPlaying"
    }
}
