package com.reelhouse.android.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Podcasts
import androidx.compose.material.icons.filled.Settings
import androidx.compose.ui.graphics.vector.ImageVector

// Internal rather than private so TabBarLayout's unit tests can reach it.
internal enum class AppSection(
    val title: String,
    val route: String,
) {
    MOVIES("Movies", "movies"),
    MUSIC("Music", "music"),
    PODCASTS("Podcasts", "podcasts"),
    SETTINGS("Settings", "settings"),
    ;

    // Looked up on use rather than held in the constructor, so building the enum - which the
    // plain-JVM unit tests do - never touches Compose's icon builders.
    val icon: ImageVector
        get() = when (this) {
            MOVIES -> Icons.Default.Movie
            MUSIC -> Icons.Default.LibraryMusic
            PODCASTS -> Icons.Default.Podcasts
            SETTINGS -> Icons.Default.Settings
        }

    companion object {
        // Movies & TV, Music and Podcasts can each be switched off server-side; Settings is
        // always there. Named arguments at every call site: booleans in a row are one positional
        // slip away from gating the wrong section.
        fun visible(
            moviesEnabled: Boolean = false,
            musicEnabled: Boolean = false,
            podcastsEnabled: Boolean = false,
        ): List<AppSection> =
            entries.filter {
                (it != MOVIES || moviesEnabled) &&
                    (it != MUSIC || musicEnabled) &&
                    (it != PODCASTS || podcastsEnabled)
            }
    }
}
