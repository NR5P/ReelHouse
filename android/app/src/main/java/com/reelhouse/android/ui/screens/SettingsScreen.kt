package com.reelhouse.android.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.reelhouse.android.BuildConfig
import com.reelhouse.android.data.DiagnosticEntry
import com.reelhouse.android.data.DiagnosticLevel
import com.reelhouse.android.data.pushStatusSummary
import com.reelhouse.android.ui.ReelHouseUiState
import com.reelhouse.android.ui.ReelHouseViewModel
import com.reelhouse.android.ui.components.ConnectionBadge
import com.reelhouse.android.ui.components.shortTime
import com.reelhouse.android.ui.theme.ReelHouseCurtain
import com.reelhouse.android.ui.theme.ReelHouseGold
import com.reelhouse.android.ui.theme.ReelHouseRed
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(
    state: ReelHouseUiState,
    model: ReelHouseViewModel,
    onManageAccounts: () -> Unit,
    onDashboardLogin: () -> Unit,
    onAcknowledgements: () -> Unit = {},
    onServerSettings: () -> Unit,
    onMediaLibraries: () -> Unit = {},
    // Music & Podcasts on this phone (speaker, downloads, equalizer...), when either tab is on.
    onMusicAndPodcasts: (() -> Unit)? = null,
    // Set while the phone-width bottom bar is in use; the tablet's rail shows every section and
    // has nothing to customize. See TabBarLayout.
    onCustomizeTabBar: (() -> Unit)? = null,
) {
    var address by rememberSaveable { mutableStateOf(state.serverUrl) }
    var remoteAddress by rememberSaveable { mutableStateOf(state.remoteServerUrl) }
    var showDiagnostics by rememberSaveable { mutableStateOf(false) }
    var showChangePassword by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(state.serverUrl) { address = state.serverUrl }
    LaunchedEffect(state.remoteServerUrl) { remoteAddress = state.remoteServerUrl }
    LaunchedEffect(Unit) { model.refreshPushStatus() }
    // On every return to the screen: the way back from the system notification settings.
    LifecycleResumeEffect(Unit) {
        model.refreshNotificationPermission()
        onPauseOrDispose { }
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Settings", state)
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (onCustomizeTabBar != null) {
                item {
                    SettingsSection("Tab bar") {
                        TextButton(onClick = onCustomizeTabBar, modifier = Modifier.fillMaxWidth()) {
                            Text("Customize tab bar", color = ReelHouseGold, modifier = Modifier.weight(1f))
                        }
                        Text(
                            "Choose which sections have a tab at the bottom of the screen. The rest are under More.",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            item {
                SettingsSection("Server") {
                    OutlinedTextField(
                        value = address,
                        onValueChange = { address = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Dashboard address") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = remoteAddress,
                        onValueChange = { remoteAddress = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Remote address (optional)") },
                        placeholder = { Text("https://your-tunnel.example.com") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        singleLine = true,
                    )
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Status")
                        Spacer(Modifier.weight(1f))
                        if (state.hasRemoteServerUrl || state.isUsingHttpFallback) {
                            Text(
                                when {
                                    state.isUsingRemote -> "via Remote"
                                    // Worth naming: the address says https, the connection isn't.
                                    state.isUsingHttpFallback -> "via Local (HTTP)"
                                    else -> "via Local"
                                },
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(end = 8.dp),
                            )
                        }
                        ConnectionBadge(state.connectionState)
                    }
                    Text(
                        "A Cloudflare Tunnel (or any other externally-reachable) address to use " +
                            "when the local address can't be reached, such as away from home on cellular. " +
                            "Point it at the server's Internet Exposed port, not the normal dashboard port — " +
                            "that port always requires a login, while the normal one trusts the local network.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(
                        onClick = { model.saveServers(address, remoteAddress) },
                        enabled = address.isNotBlank() && !state.isLoading,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Save and Reconnect")
                    }
                }
            }

            if (onMusicAndPodcasts != null) {
                item {
                    SettingsSection("Music & Podcasts") {
                        TextButton(onClick = onMusicAndPodcasts, modifier = Modifier.fillMaxWidth()) {
                            Text("Music & Podcasts on this phone", color = ReelHouseGold, modifier = Modifier.weight(1f))
                        }
                        Text(
                            "Let others play here, announcements, data saver, downloads, equalizer, alarms and ListenBrainz." +
                                if (state.isAdmin) " The music libraries and podcast folder are under Server Settings → MUSIC and PODCASTS." else "",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            item { NotificationsSection(state, model) }

            item {
                SettingsSection("Account") {
                    state.authStatus?.username?.let {
                        SettingsRow("Signed in as", it)
                    }
                    state.authStatus?.role?.let {
                        SettingsRow("Role", it.replaceFirstChar(Char::uppercase))
                    }
                    if (state.authStatus?.enabled == true) {
                        OutlinedButton(
                            onClick = { showChangePassword = true },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Change Password")
                        }
                        OutlinedButton(
                            onClick = model::signOut,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Sign Out", color = ReelHouseRed)
                        }
                    } else {
                        Text(
                            "Dashboard login is not enabled.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            // Account, library and server administration is all AdminOnly on the server - hidden
            // entirely for a Viewer rather than shown-disabled.
            if (state.isAdmin) {
                item {
                    SettingsSection("Accounts") {
                        TextButton(
                            onClick = onManageAccounts,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Manage Accounts", color = ReelHouseGold, modifier = Modifier.weight(1f))
                        }
                        // The switch itself, as opposed to the accounts it governs - the web
                        // dashboard's LOGIN section, which had no counterpart here until now.
                        TextButton(
                            onClick = onDashboardLogin,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Dashboard Login", color = ReelHouseGold, modifier = Modifier.weight(1f))
                        }
                        Text(
                            "Whether opening the dashboard requires a login at all, and who can.",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                item {
                    SettingsSection("Movies & TV") {
                        TextButton(
                            onClick = onMediaLibraries,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Movies & TV libraries", color = ReelHouseGold, modifier = Modifier.weight(1f))
                        }
                        Text(
                            "The folders the Movies tab reads from, on the server or on other computers on your network.",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                item {
                    SettingsSection("Server Configuration") {
                        TextButton(
                            onClick = onServerSettings,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Server Settings", color = ReelHouseGold, modifier = Modifier.weight(1f))
                        }
                        Text(
                            "Every server setting the web dashboard has — Movies & TV, Music, Podcasts, downloads, and more.",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            state.lastError?.let { error ->
                item {
                    SettingsSection("System") {
                        Text(error, color = ReelHouseRed)
                    }
                }
            }

            item {
                SettingsSection("About") {
                    SettingsRow("App version", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                    TextButton(onClick = onAcknowledgements, modifier = Modifier.fillMaxWidth()) {
                        Text("Acknowledgements", color = ReelHouseGold, modifier = Modifier.weight(1f))
                    }
                }
            }

            item {
                SettingsSection("Diagnostics") {
                    TextButton(
                        onClick = { showDiagnostics = !showDiagnostics },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            "Connection Log",
                            color = ReelHouseGold,
                            modifier = Modifier.weight(1f),
                        )
                        Icon(
                            if (showDiagnostics) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                            contentDescription = if (showDiagnostics) "Collapse log" else "Expand log",
                        )
                    }
                    AnimatedVisibility(showDiagnostics) {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            if (state.diagnostics.isEmpty()) {
                                Text(
                                    "No requests recorded yet.",
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            } else {
                                state.diagnostics.take(30).forEach { DiagnosticRow(it) }
                            }
                            TextButton(onClick = model::clearDiagnostics) {
                                Text("Clear Log")
                            }
                        }
                    }
                    Text(
                        "Request bodies, passwords, cookies, and server response contents are never written here.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            item {
                Text(
                    "This app manages its own connection. Server settings " +
                        "edited here and on the web dashboard are the same settings - a change in " +
                        "either place shows up in both.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
                        .fillMaxWidth()
                        .widthIn(max = 900.dp),
                )
            }
        }
    }

    if (showChangePassword) {
        ChangePasswordDialog(model = model, onDismiss = { showChangePassword = false })
    }
}

// Push notifications (push/PushNotifications): whether Android will show them, what the server
// says, and a test send. Which podcasts notify is per show, on each show's screen.
@Composable
private fun NotificationsSection(state: ReelHouseUiState, model: ReelHouseViewModel) {
    val context = LocalContext.current
    SettingsSection("Notifications") {
        SettingsRow("On this phone", if (state.notificationsAllowed) "Allowed" else "Blocked")
        if (!state.notificationsAllowed) {
            Text(
                "Android won't show ReelHouse's notifications - new episodes, finished downloads, " +
                    "sign-in alerts, or the player's controls.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedButton(
                onClick = {
                    val intent = android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
                    runCatching { context.startActivity(intent) }
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Open notification settings")
            }
        }
        Text(
            pushStatusSummary(state.pushAvailable, state.pushStatus, state.pushUnsupported),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (state.pushAvailable) {
            OutlinedButton(
                onClick = model::sendTestPush,
                enabled = state.pushDeliverable && !state.pushTestRunning,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (state.pushTestRunning) "Sending…" else "Send test notification")
            }
            state.pushMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        if (state.podcastsEnabled) {
            Text(
                "Which podcasts notify you is set per show: open the show's settings and turn on " +
                    "Notify me of new episodes.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ChangePasswordDialog(model: ReelHouseViewModel, onDismiss: () -> Unit) {
    var currentPassword by rememberSaveable { mutableStateOf("") }
    var newPassword by rememberSaveable { mutableStateOf("") }
    var confirmPassword by rememberSaveable { mutableStateOf("") }
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    val mismatch = confirmPassword.isNotEmpty() && newPassword != confirmPassword
    val canSave = currentPassword.isNotEmpty() && newPassword.length >= 8 && newPassword == confirmPassword

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Change Password") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = currentPassword,
                    onValueChange = { currentPassword = it },
                    label = { Text("Current password") },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = newPassword,
                    onValueChange = { newPassword = it },
                    label = { Text("New password (min. 8 characters)") },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = confirmPassword,
                    onValueChange = { confirmPassword = it },
                    label = { Text("Confirm new password") },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (mismatch) {
                    Text("New passwords don't match.", color = ReelHouseRed)
                }
                errorMessage?.let { Text(it, color = ReelHouseRed) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = canSave && !isSaving,
                onClick = {
                    scope.launch {
                        isSaving = true
                        errorMessage = null
                        try {
                            model.changeMyPassword(currentPassword, newPassword)
                            onDismiss()

                            // The server ends every session for the account when the password
                            // changes, this device's included, so that a session somebody else is
                            // holding stops working. Reconnecting immediately turns that into a
                            // sign-in prompt rather than leaving the app looking connected until
                            // whatever the user does next quietly fails.
                            model.connect()
                        } catch (error: Exception) {
                            errorMessage = error.message ?: "Could not change the password."
                        } finally {
                            isSaving = false
                        }
                    }
                },
            ) {
                Text(if (isSaving) "Saving…" else "Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun SettingsSection(
    title: String,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth().widthIn(max = 900.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, color = ReelHouseCurtain)
        Card(Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                content()
            }
        }
    }
}

@Composable
private fun SettingsRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(value)
    }
}

// Monospace is kept here on purpose - this is genuinely tabular/log content, unlike the rest of
// the screen's now-system-font text (see Theme.kt for why the app no longer forces it globally).
@Composable
private fun DiagnosticRow(entry: DiagnosticEntry) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row {
            Text(
                entry.level.name,
                color = if (entry.level == DiagnosticLevel.ERROR) ReelHouseRed else ReelHouseCurtain,
                fontFamily = FontFamily.Monospace,
            )
            Spacer(Modifier.weight(1f))
            Text(
                entry.timestamp.shortTime(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontFamily = FontFamily.Monospace,
            )
        }
        SelectionContainer {
            Text(entry.message, fontFamily = FontFamily.Monospace)
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.25f))
    }
}
