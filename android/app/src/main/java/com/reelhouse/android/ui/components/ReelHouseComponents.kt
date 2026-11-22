package com.reelhouse.android.ui.components

import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.reelhouse.android.data.ConnectionState
import com.reelhouse.android.ui.theme.ReelHouseAmber
import com.reelhouse.android.ui.theme.ReelHouseCard
import com.reelhouse.android.ui.theme.ReelHouseGold
import com.reelhouse.android.ui.theme.ReelHouseGoldDim
import com.reelhouse.android.ui.theme.ReelHouseRed
import com.reelhouse.android.ui.theme.ReelHouseTextDim
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

// Reserved for surfaces that should still look distinctly "ReelHouse" rather than a generic
// Material container - today just the setup/login card. Everywhere else that used to reach for
// this (event rows, grid tiles, settings sections) now uses a plain Card instead.
@Composable
fun BrandedCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .background(ReelHouseCard)
            .border(1.dp, ReelHouseGoldDim.copy(alpha = 0.45f), RoundedCornerShape(8.dp))
            .padding(14.dp),
    ) {
        // A Box sets no content colour, so plain Text inside fell back to black - invisible on the
        // dark card wherever no Scaffold/Surface above provides one (the first-run setup screen's
        // welcome text, on a phone in dark mode).
        CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurface) {
            content()
        }
    }
}

@Composable
fun ConnectionBadge(
    state: ConnectionState,
    modifier: Modifier = Modifier,
) {
    val color = when (state) {
        ConnectionState.ONLINE -> ReelHouseGold
        ConnectionState.CHECKING,
        ConnectionState.AUTHENTICATION_REQUIRED,
        -> ReelHouseAmber
        ConnectionState.OFFLINE -> ReelHouseRed
        ConnectionState.NOT_CONFIGURED -> ReelHouseTextDim
    }
    Row(
        modifier = modifier.semantics {
            contentDescription = "Server status: ${state.label}"
        },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Text(
            text = state.label,
            color = ReelHouseTextDim,
            style = MaterialTheme.typography.labelSmall,
            maxLines = 1,
        )
    }
}

@Composable
fun EmptyState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            imageVector = Icons.Default.Shield,
            contentDescription = null,
            tint = ReelHouseTextDim,
            modifier = Modifier.size(42.dp),
        )
        Text(title, color = ReelHouseTextDim, style = MaterialTheme.typography.titleMedium)
        Text(
            message,
            color = ReelHouseTextDim,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

fun Instant.relativeTime(now: Instant = Instant.now()): String {
    val duration = Duration.between(this, now)
    val seconds = duration.seconds.coerceAtLeast(0)
    return when {
        seconds < 60 -> "now"
        seconds < 3_600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3_600}h ago"
        seconds < 604_800 -> "${seconds / 86_400}d ago"
        else -> DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
            .withLocale(Locale.getDefault())
            .withZone(ZoneId.systemDefault())
            .format(this)
    }
}

fun Instant.fullDateTime(): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.FULL, FormatStyle.MEDIUM)
        .withLocale(Locale.getDefault())
        .withZone(ZoneId.systemDefault())
        .format(this)

fun Instant.shortTime(): String =
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault())
        .withZone(ZoneId.systemDefault())
        .format(this)

