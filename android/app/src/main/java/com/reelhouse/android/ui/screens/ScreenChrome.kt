package com.reelhouse.android.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.reelhouse.android.ui.ReelHouseUiState
import com.reelhouse.android.ui.components.ConnectionBadge

// The bars and rows every screen shares: a top-level tab's header (title, connection badge,
// optional Refresh), a pushed screen's header (title, Back), and a label/value row.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenHeader(
    title: String,
    state: ReelHouseUiState,
    onRefresh: (() -> Unit)? = null,
    // Extra buttons alongside Refresh, for top-level screens that have their own actions.
    actions: @Composable RowScope.() -> Unit = {},
) {
    TopAppBar(
        title = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                ConnectionBadge(state.connectionState)
            }
        },
        actions = {
            actions()
            if (onRefresh != null) {
                IconButton(onClick = onRefresh, enabled = !state.isLoading) {
                    Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                }
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailHeader(
    title: String,
    onBack: () -> Unit,
    actions: @Composable RowScope.() -> Unit = {},
) {
    TopAppBar(
        title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
        },
        actions = actions,
    )
}

@Composable
fun MetadataRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.weight(1f))
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
