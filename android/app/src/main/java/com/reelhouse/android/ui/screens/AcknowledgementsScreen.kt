package com.reelhouse.android.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.reelhouse.android.ui.ReelHouseUiState
import com.reelhouse.android.ui.theme.ReelHouseGold

// Credits for the data services the server draws on and the open-source code in this app. TMDB's
// terms ask for the notice below wherever its data is shown; the rest is courtesy and license
// attribution.
private data class Credit(val name: String, val detail: String, val url: String)

private val dataCredits = listOf(
    Credit(
        "The Movie Database (TMDB)",
        "Movie and TV descriptions and artwork, when your server has a TMDB key. This product uses the " +
            "TMDB API but is not endorsed or certified by TMDB.",
        "https://www.themoviedb.org",
    ),
    Credit("MusicBrainz and Cover Art Archive", "Album details and cover art the server looks up for your music.", "https://musicbrainz.org"),
    Credit("ListenBrainz", "Similar-artist suggestions and listening history, if you connect an account.", "https://listenbrainz.org"),
    Credit("LRCLIB", "Song lyrics.", "https://lrclib.net"),
)

private val codeCredits = listOf(
    Credit(
        "Android Jetpack (AndroidX, Compose, Media3, WorkManager)",
        "Copyright The Android Open Source Project; Apache License 2.0.",
        "https://developer.android.com/jetpack",
    ),
    Credit("Kotlin coroutines", "Copyright JetBrains s.r.o.; Apache License 2.0.", "https://github.com/Kotlin/kotlinx.coroutines"),
)

@Composable
fun AcknowledgementsScreen(state: ReelHouseUiState, onBack: () -> Unit) {
    val uriHandler = LocalUriHandler.current
    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Acknowledgements", state)
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null)
                    Text("Back to Settings", modifier = Modifier.weight(1f).padding(start = 8.dp))
                }
            }
            item { SectionTitle("Data") }
            items(dataCredits) { CreditCard(it) { uriHandler.openUri(it.url) } }
            item { SectionTitle("Open-source software") }
            items(codeCredits) { CreditCard(it) { uriHandler.openUri(it.url) } }
            item {
                Text(
                    "ReelHouse is an independent project. It is not affiliated with or endorsed by any " +
                        "media company or service named in the app.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
                )
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        color = ReelHouseGold,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.padding(horizontal = 18.dp, vertical = 4.dp),
    )
}

@Composable
private fun CreditCard(credit: Credit, onOpen: () -> Unit) {
    Card(Modifier.fillMaxWidth().padding(horizontal = 14.dp).clickable(onClick = onOpen)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(credit.name, fontWeight = FontWeight.SemiBold, color = ReelHouseGold)
            Text(
                credit.detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
