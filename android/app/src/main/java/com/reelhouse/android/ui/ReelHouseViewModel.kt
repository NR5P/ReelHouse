package com.reelhouse.android.ui

import android.app.Application
import android.graphics.Bitmap
import android.media.MediaCodecList
import android.media.MediaFormat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.reelhouse.android.audio.AudioEnabled
import com.reelhouse.android.audio.AudioRuntime
import com.reelhouse.android.data.Account
import com.reelhouse.android.data.AuthStatus
import com.reelhouse.android.data.ConnectionState
import com.reelhouse.android.data.DiagnosticEntry
import com.reelhouse.android.data.DiagnosticLevel
import com.reelhouse.android.data.MediaApi
import com.reelhouse.android.data.MediaBrowseListing
import com.reelhouse.android.data.MediaDiscoveredComputer
import com.reelhouse.android.data.MediaHome
import com.reelhouse.android.data.MediaItemDetail
import com.reelhouse.android.data.MediaItemSummary
import com.reelhouse.android.data.MediaItemsPage
import com.reelhouse.android.data.MediaLibrary
import com.reelhouse.android.data.MediaLibraryInput
import com.reelhouse.android.data.MediaNetworkComputer
import com.reelhouse.android.data.MediaNetworkSignInInput
import com.reelhouse.android.data.MediaNetworkSignInResult
import com.reelhouse.android.data.MediaPlayback
import com.reelhouse.android.data.MediaProgress
import com.reelhouse.android.data.MediaStatus
import com.reelhouse.android.data.PushStatus
import com.reelhouse.android.data.pushTestSummary
import com.reelhouse.android.data.Reachability
import com.reelhouse.android.data.ReelHouseApiException
import com.reelhouse.android.data.ReelHouseRepository
import com.reelhouse.android.data.ServerAddress
import com.reelhouse.android.data.ServerCompatibility
import com.reelhouse.android.data.ServerIdentity
import com.reelhouse.android.data.SettingsAction
import com.reelhouse.android.data.SettingsFieldOption
import com.reelhouse.android.data.SettingsLookup
import com.reelhouse.android.data.SettingsLookupCandidate
import com.reelhouse.android.data.SettingsOptionsSource
import com.reelhouse.android.data.SettingsSection
import com.reelhouse.android.net.DiscoveredServer
import com.reelhouse.android.net.ServerDiscovery
import com.reelhouse.android.push.PushSupport
import com.reelhouse.android.push.PushTokenStore
import java.net.URI
import java.time.Instant
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ReelHouseUiState(
    val serverUrl: String = "",
    // Optional Cloudflare Tunnel (or any other externally-reachable) address, used only when
    // the local address can't be reached - see ReelHouseViewModel.connect() for the resolution.
    val remoteServerUrl: String = "",
    val activeServerUrl: String = "",
    val isUsingRemote: Boolean = false,
    // Whether the local address was an https:// one this device wouldn't trust, and the app
    // retried on the server's plain-HTTP port. Surfaced in Settings: the connection works, but
    // it is unencrypted, and that shouldn't be silent.
    val isUsingHttpFallback: Boolean = false,
    val connectionState: ConnectionState = ConnectionState.NOT_CONFIGURED,
    // Whether the server this app is talking to is older than it expects. Advisory: nothing in the
    // app behaves differently, it just says so - see ServerCompatibility.
    val serverCompatibility: ServerCompatibility = ServerCompatibility.Unknown,
    val authStatus: AuthStatus? = null,
    val accounts: List<Account> = emptyList(),
    // Whether the server has Movies & TV switched on - the MOVIES tab exists only then. Starts
    // from what the server said last time, so the tab doesn't blink in on every launch.
    val moviesEnabled: Boolean = false,
    // Music & Podcasts: each tab exists only while the server has it switched on. Starts from
    // what the server said last time.
    val musicEnabled: Boolean = false,
    val podcastsEnabled: Boolean = false,
    val isLoading: Boolean = false,
    val lastError: String? = null,
    val diagnostics: List<DiagnosticEntry> = emptyList(),
    val lastUpdated: Instant? = null,
    val discoveredServers: List<DiscoveredServer> = emptyList(),
    // Push notifications (push/PushNotifications). pushAvailable: this build has a Firebase app,
    // i.e. was built with google-services.json. Fixed for the life of the process.
    val pushAvailable: Boolean = false,
    // Whether Android will show this app's notifications: the Android 13+ permission and the
    // app-wide switch in system settings, which a person can turn off on any version.
    val notificationsAllowed: Boolean = true,
    val pushStatus: PushStatus? = null,
    // The server answered /api/push/status with 404: it predates push.
    val pushUnsupported: Boolean = false,
    val pushTestRunning: Boolean = false,
    // The last "Send test notification" result.
    val pushMessage: String? = null,
) {
    val isConfigured: Boolean
        get() = runCatching {
            val uri = URI(serverUrl)
            uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank()
        }.getOrDefault(false)

    val hasRemoteServerUrl: Boolean
        get() = runCatching {
            val uri = URI(remoteServerUrl)
            uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank()
        }.getOrDefault(false)

    val requiresLogin: Boolean
        get() = authStatus?.let { it.enabled && !it.authenticated } == true

    // Absent role (older server, or login not required) reads as Admin - matches the server's
    // own AuthGateMiddleware treatment of "no login required" as full access for everyone.
    val isAdmin: Boolean
        get() = (authStatus?.role ?: "Admin") == "Admin"

    // Push can actually reach this phone - the point at which asking for the notification
    // permission is worth an interruption.
    val pushDeliverable: Boolean
        get() = pushAvailable && pushStatus?.enabled == true && pushStatus.androidConfigured
}

class ReelHouseViewModel(application: Application) : AndroidViewModel(application) {
    private val preferences =
        application.getSharedPreferences("reelhouse", Application.MODE_PRIVATE)
    private val logSequence = AtomicLong()
    private val repository = ReelHouseRepository(application, ::log)
    private val serverIdentity = ServerIdentity(application)

    // Set by resolveActiveServerUrl when something at the local address failed the identity check,
    // so the connection that follows reports that instead of a bare certificate error.
    private var identityRefusal: String? = null

    // The shared player, downloads and speaker - process-wide.
    val audio: AudioRuntime = AudioRuntime.get(application)
    private val serverDiscovery = ServerDiscovery(application)
    private val _state = MutableStateFlow(
        ReelHouseUiState(
            serverUrl = preferences.getString(SERVER_URL_KEY, "").orEmpty(),
            remoteServerUrl = preferences.getString(REMOTE_SERVER_URL_KEY, "").orEmpty(),
            moviesEnabled = preferences.getBoolean(MOVIES_ENABLED_KEY, false),
            musicEnabled = AudioRuntime.get(application).enabled.value.music,
            podcastsEnabled = AudioRuntime.get(application).enabled.value.podcasts,
            pushAvailable = PushSupport.isAvailable(application),
        ),
    )
    val state: StateFlow<ReelHouseUiState> = _state.asStateFlow()

    private var connectionJob: Job? = null

    // "server|account|token" last registered for push, so the 30-second reconnect loop doesn't
    // register again every time - and a new token, account or server does. Cleared on sign-out
    // and when the server changes. The mutex keeps a token arriving mid-registration from
    // sending a second, simultaneous one.
    private var pushRegisteredKey: String? = null
    private var pushStatusKey: String? = null
    private val pushMutex = Mutex()

    init {
        repository.baseUrl = _state.value.serverUrl
        // Music & Podcasts share this repository, and outlive this ViewModel: the playback
        // service keeps the process alive. See audio/AudioRuntime.
        audio.attach(repository)
        viewModelScope.launch {
            serverDiscovery.servers.collect { servers ->
                _state.update { it.copy(discoveredServers = servers) }
            }
        }
        refreshNotificationPermission()
        // Firebase rotated the token (ReelHouseMessagingService.onNewToken) while the app is open.
        viewModelScope.launch {
            PushTokenStore.updates.collect { token -> if (!token.isNullOrBlank()) onSessionReady() }
        }
    }

    // Local-network discovery is only useful before a server is configured - see ServerDiscovery
    // and ReelHouseApp's LaunchedEffect(state.isConfigured) that drives these.
    fun startDiscovery() = serverDiscovery.start()

    fun stopDiscovery() = serverDiscovery.stop()

    override fun onCleared() {
        super.onCleared()
        serverDiscovery.stop()
    }

    fun connect(resetNetworkSession: Boolean = false) {
        if (!_state.value.isConfigured) {
            _state.update { it.copy(connectionState = ConnectionState.NOT_CONFIGURED) }
            return
        }
        if (connectionJob?.isActive == true) {
            log("Connection request skipped because one is already active", DiagnosticLevel.NOTICE)
            return
        }

        connectionJob = viewModelScope.launch {
            val wasOffline = _state.value.connectionState == ConnectionState.OFFLINE
            if (_state.value.connectionState != ConnectionState.ONLINE) {
                _state.update { it.copy(connectionState = ConnectionState.CHECKING) }
            }
            if (resetNetworkSession || wasOffline) repository.resetSession()
            log("Connecting to ${_state.value.serverUrl}", DiagnosticLevel.INFO)
            identityRefusal = null
            resolveActiveServerUrl()

            try {
                val auth = repository.authStatus()
                _state.update { it.copy(authStatus = auth) }
                // Before the authentication return below, so the advisory is already known at the
                // login screen. Never throws - see checkServerCompatibility.
                checkServerCompatibility()
                if (auth.enabled && !auth.authenticated) {
                    log("Server requires dashboard authentication", DiagnosticLevel.INFO)
                    _state.update {
                        it.copy(connectionState = ConnectionState.AUTHENTICATION_REQUIRED)
                    }
                    return@launch
                }
                refreshAll()
                _state.update { it.copy(connectionState = ConnectionState.ONLINE) }
                log("Connection established", DiagnosticLevel.INFO)
                audio.onConnected()
                onSessionReady()
            } catch (error: Exception) {
                _state.update {
                    it.copy(
                        connectionState = if (error is ReelHouseApiException && error.statusCode == 401) {
                            ConnectionState.AUTHENTICATION_REQUIRED
                        } else {
                            ConnectionState.OFFLINE
                        },
                        lastError = identityRefusal ?: readableError(error),
                    )
                }
                log("Connection failed: ${readableError(error)}", DiagnosticLevel.ERROR)
            }
        }
    }

    // Deliberately swallows every failure. This is a diagnostic nicety layered on top of a
    // connection that has already succeeded - failing the connect() that called it, over a server
    // that merely declined to describe itself, would turn a cosmetic feature into an outage.
    // Cancellation is rethrown rather than reported: it means the connect job itself was torn
    // down, which is the app working correctly and not something to log as a version problem.
    private suspend fun checkServerCompatibility() {
        val compatibility = try {
            ServerCompatibility.evaluate(repository.serverHealth())
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            log("Could not read the server's version: ${readableError(error)}", DiagnosticLevel.INFO)
            ServerCompatibility.Unknown
        }
        _state.update { it.copy(serverCompatibility = compatibility) }
        compatibility.advisory?.let { log(it, DiagnosticLevel.NOTICE) }
    }

    // Prefers the local address whenever it's reachable at all (any HTTP response counts, not
    // just 2xx) and only falls back to the remote address on an actual network failure - this
    // runs at the top of every connect(), so moving between home and away self-heals on the
    // next reconnect without any WiFi/SSID detection.
    private suspend fun resolveActiveServerUrl() {
        val current = _state.value
        val httpFallback = ServerAddress.httpFallback(current.serverUrl)

        // Probing costs a round trip, and is only worth it when there is somewhere else to go.
        if (!current.hasRemoteServerUrl && httpFallback == null) {
            useServerUrl(current.serverUrl, isRemote = false, isHttpFallback = false)
            return
        }

        when (repository.probe(current.serverUrl)) {
            Reachability.REACHABLE -> {
                useServerUrl(current.serverUrl, isRemote = false, isHttpFallback = false)
                return
            }
            // Tried before the remote address, not after: an untrusted local certificate says
            // nothing about which network this device is on, and the server's own plain-HTTP port
            // is a better answer than sending home traffic out over the Internet and back.
            //
            // The fallback is derived from the local address only. Quietly dropping encryption on
            // the remote address would be doing it across the open Internet, which is a different
            // proposition entirely - and, when that address is fronted by a TLS-terminating proxy,
            // lands on a Secure session cookie this app cannot return anyway.
            //
            // And only to a server that proves it is this one (see ServerIdentity). A server that
            // hasn't yet - the first fallback, before its authority is remembered - gets none of
            // the existing session: it is dropped, and the sign-in screen asks for the password.
            Reachability.CERTIFICATE_UNTRUSTED -> if (httpFallback != null) {
                val identity = serverIdentity.check(current.serverUrl)
                when (identity) {
                    ServerIdentity.Check.Mismatch -> {
                        log(
                            "The server at ${current.serverUrl} presented a certificate its own " +
                                "authority didn't sign - not falling back to plain HTTP",
                            DiagnosticLevel.ERROR,
                        )
                        identityRefusal = IMPOSTOR_MESSAGE
                    }
                    ServerIdentity.Check.Unavailable -> log(
                        "Couldn't check the certificate at ${current.serverUrl} before falling " +
                            "back to plain HTTP",
                        DiagnosticLevel.NOTICE,
                    )
                    ServerIdentity.Check.Verified, is ServerIdentity.Check.Unknown -> {
                        if (identity is ServerIdentity.Check.Unknown) repository.forgetSession(httpFallback)
                        if (useHttpFallback(current.serverUrl, httpFallback, identity)) return
                    }
                }
            }
            Reachability.UNREACHABLE -> Unit
        }

        if (!current.hasRemoteServerUrl) {
            // Nothing left to try. Go with the configured address anyway, so the connection that
            // follows reports the server's own error rather than a probe's silent verdict.
            useServerUrl(current.serverUrl, isRemote = false, isHttpFallback = false)
            return
        }
        log("Local address unreachable; using remote address", DiagnosticLevel.INFO)
        useServerUrl(current.remoteServerUrl, isRemote = true, isHttpFallback = false)
    }

    // The plain-HTTP rung of resolveActiveServerUrl, once the identity check has allowed it. True
    // when it was taken.
    private suspend fun useHttpFallback(
        httpsAddress: String,
        httpFallback: String,
        identity: ServerIdentity.Check,
    ): Boolean {
        log(
            "This device does not trust the server's HTTPS certificate; trying the " +
                "plain-HTTP port at $httpFallback",
            DiagnosticLevel.NOTICE,
        )
        if (repository.probe(httpFallback) == Reachability.REACHABLE) {
            if (identity is ServerIdentity.Check.Unknown) {
                rememberServerIdentity(identity, httpsAddress, httpFallback)
            }
            log(
                "Using $httpFallback. To connect over HTTPS instead, install the server's " +
                    "certificate authority (ca.crt) on this device - see DEPLOYMENT.md " +
                    "section 14a.",
                DiagnosticLevel.NOTICE,
            )
            useServerUrl(httpFallback, isRemote = false, isHttpFallback = true)
            return true
        }
        log("The plain-HTTP port at $httpFallback did not answer either", DiagnosticLevel.NOTICE)
        return false
    }

    // Trust on first use - see ServerIdentity. Best effort: failing to remember just means the
    // next fallback is treated as a first one again.
    private suspend fun rememberServerIdentity(
        identity: ServerIdentity.Check.Unknown,
        httpsAddress: String,
        httpAddress: String,
    ) {
        val authority = ServerIdentity.fetchAuthority(httpAddress)
        when {
            authority == null ->
                log("Couldn't download the server's certificate authority to remember it", DiagnosticLevel.NOTICE)
            serverIdentity.remember(authority, identity.leaf, httpsAddress) ->
                log(
                    "Remembered this server's certificate authority; plain-HTTP fallback now only " +
                        "goes to this server",
                    DiagnosticLevel.NOTICE,
                )
            else -> log(
                "The certificate authority the server offered didn't sign its HTTPS certificate - " +
                    "not remembering it",
                DiagnosticLevel.NOTICE,
            )
        }
    }

    private fun useServerUrl(url: String, isRemote: Boolean, isHttpFallback: Boolean) {
        repository.baseUrl = url
        _state.update {
            it.copy(
                activeServerUrl = url,
                isUsingRemote = isRemote,
                isUsingHttpFallback = isHttpFallback,
            )
        }
    }

    // Which sections the server has switched on. Neither answer failing fails the connection: a
    // failed request keeps what was known last time.
    suspend fun refreshAll() {
        _state.update { it.copy(isLoading = true) }
        try {
            val requests = listOf(
                viewModelScope.async {
                    runCatching { repository.mediaEnabled() }
                        .onSuccess(::setMoviesEnabled)
                        .onFailure { error ->
                            if (error is ReelHouseApiException && error.statusCode == 404) setMoviesEnabled(false)
                        }
                },
                // Music & Podcasts: /api/audio/enabled always answers; a server without it 404s,
                // which the API reads as both off. A failed request keeps what was known.
                viewModelScope.async {
                    runCatching { audio.api.enabled() }
                        .onSuccess(::setAudioEnabled)
                },
            )
            requests.awaitAll()
            _state.update { it.copy(lastError = null, lastUpdated = Instant.now()) }
        } finally {
            _state.update { it.copy(isLoading = false) }
        }
    }

    fun saveServer(address: String) {
        val normalized = ReelHouseRepository.normalizeAddress(address)
        connectionJob?.cancel()
        repository.clearAuthenticationSession()
        forgetPushSession()
        // Saving the address is the way past a server whose certificate authority changed (a
        // reinstall) - see ServerIdentity.
        serverIdentity.forget(normalized)
        repository.baseUrl = normalized
        preferences.edit().putString(SERVER_URL_KEY, normalized).apply()
        _state.update {
            ReelHouseUiState(
                serverUrl = normalized,
                remoteServerUrl = it.remoteServerUrl,
                diagnostics = it.diagnostics,
                pushAvailable = it.pushAvailable,
                notificationsAllowed = it.notificationsAllowed,
                connectionState = if (normalized.isBlank()) {
                    ConnectionState.NOT_CONFIGURED
                } else {
                    ConnectionState.CHECKING
                },
            )
        }
        connect(resetNetworkSession = true)
    }

    // Saves both addresses and reconnects exactly once - saveServer()/a hypothetical
    // saveRemoteServer() called back-to-back would each independently trigger connect(),
    // racing against connect()'s own "already active" guard.
    fun saveServers(localAddress: String, remoteAddress: String) {
        val normalizedLocal = ReelHouseRepository.normalizeAddress(localAddress)
        val normalizedRemote = if (remoteAddress.isBlank()) "" else ReelHouseRepository.normalizeAddress(remoteAddress, defaultScheme = "https")
        connectionJob?.cancel()
        repository.clearAuthenticationSession()
        forgetPushSession()
        serverIdentity.forget(normalizedLocal)
        repository.baseUrl = normalizedLocal
        preferences.edit()
            .putString(SERVER_URL_KEY, normalizedLocal)
            .putString(REMOTE_SERVER_URL_KEY, normalizedRemote)
            .apply()
        _state.update {
            ReelHouseUiState(
                serverUrl = normalizedLocal,
                remoteServerUrl = normalizedRemote,
                diagnostics = it.diagnostics,
                pushAvailable = it.pushAvailable,
                notificationsAllowed = it.notificationsAllowed,
                connectionState = if (normalizedLocal.isBlank()) {
                    ConnectionState.NOT_CONFIGURED
                } else {
                    ConnectionState.CHECKING
                },
            )
        }
        connect(resetNetworkSession = true)
    }

    fun signIn(username: String, password: String, onFinished: (String?) -> Unit) {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, lastError = null) }
            try {
                repository.login(username, password)
                val auth = repository.authStatus()
                _state.update { it.copy(authStatus = auth) }
                refreshAll()
                _state.update { it.copy(connectionState = ConnectionState.ONLINE) }
                onSessionReady()
                onFinished(null)
            } catch (error: Exception) {
                val message = readableError(error)
                _state.update { it.copy(lastError = message) }
                log("Sign in failed: $message", DiagnosticLevel.ERROR)
                onFinished(message)
            } finally {
                _state.update { it.copy(isLoading = false) }
            }
        }
    }

    fun signOut() {
        viewModelScope.launch {
            // Before logout: the server only takes the unregister from the signed-in session,
            // and it stops this phone getting the account's notifications after it's handed on.
            unregisterPush()
            runCatching { repository.logout() }
            repository.clearAuthenticationSession()
            val auth = runCatching { repository.authStatus() }.getOrNull()
            _state.update {
                it.copy(
                    authStatus = auth,
                    connectionState = if (auth?.enabled == true) {
                        ConnectionState.AUTHENTICATION_REQUIRED
                    } else {
                        ConnectionState.ONLINE
                    },
                )
            }
        }
    }

    // ---------------- Push notifications ----------------

    // Signed in (or no login needed) and online. Runs on every reconnect; the keys make the
    // repeats free.
    private fun onSessionReady() {
        if (!_state.value.pushAvailable) return
        viewModelScope.launch {
            val current = _state.value
            val statusKey = "${current.activeServerUrl}|${current.authStatus?.username}"
            if (statusKey != pushStatusKey) {
                pushStatusKey = statusKey
                loadPushStatus()
            }
            registerPush()
        }
    }

    // Registers this install's FCM token with the server, unless it already is. Registered even
    // while push is off on the server, so it works the moment an admin turns it on.
    private suspend fun registerPush() = pushMutex.withLock {
        val current = _state.value
        if (!current.pushAvailable || current.requiresLogin || current.connectionState != ConnectionState.ONLINE) return@withLock
        val token = try {
            PushSupport.token(getApplication())
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            // No Google Play services, or no route to Firebase: nothing to register, and nothing
            // worth more than a log line - the rest of the app is unaffected.
            log("Could not get a push token from Firebase: ${readableError(error)}", DiagnosticLevel.NOTICE)
            null
        } ?: return@withLock
        val key = "${current.activeServerUrl}|${current.authStatus?.username}|$token"
        if (key == pushRegisteredKey) return@withLock
        try {
            repository.registerPushDevice(token, deviceName())
            pushRegisteredKey = key
            log("Registered this device for push notifications", DiagnosticLevel.INFO)
            loadPushStatus()
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            log("Could not register for push notifications: ${readableError(error)}", DiagnosticLevel.NOTICE)
        }
    }

    // Best effort: an unreachable server just keeps a token it will find is dead the next time
    // it sends.
    private suspend fun unregisterPush() {
        val token = PushTokenStore.get(getApplication())
        if (_state.value.pushAvailable && !token.isNullOrBlank()) {
            try {
                repository.unregisterPushDevice(token)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Exception) {
                log("Could not unregister this device from push notifications: ${readableError(error)}", DiagnosticLevel.NOTICE)
            }
        }
        forgetPushSession()
    }

    private fun forgetPushSession() {
        pushRegisteredKey = null
        pushStatusKey = null
        _state.update { it.copy(pushStatus = null, pushUnsupported = false, pushMessage = null) }
    }

    // Settings -> Notifications, each time it opens.
    fun refreshPushStatus() {
        if (!_state.value.pushAvailable) return
        viewModelScope.launch { loadPushStatus() }
    }

    private suspend fun loadPushStatus() {
        try {
            val status = repository.pushStatus()
            _state.update { it.copy(pushStatus = status, pushUnsupported = false) }
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: ReelHouseApiException) {
            if (error.statusCode == 404) _state.update { it.copy(pushStatus = null, pushUnsupported = true) }
            log("Could not read push notification status: ${readableError(error)}", DiagnosticLevel.NOTICE)
        } catch (error: Exception) {
            log("Could not read push notification status: ${readableError(error)}", DiagnosticLevel.NOTICE)
        }
    }

    fun refreshNotificationPermission() {
        val allowed = androidx.core.app.NotificationManagerCompat.from(getApplication()).areNotificationsEnabled()
        _state.update { it.copy(notificationsAllowed = allowed) }
    }

    fun sendTestPush() {
        if (_state.value.pushTestRunning) return
        viewModelScope.launch {
            _state.update { it.copy(pushTestRunning = true, pushMessage = null) }
            // A test straight after sign-in would otherwise race this device's own registration.
            registerPush()
            val message = try {
                pushTestSummary(repository.testPushNotification())
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Exception) {
                readableError(error)
            }
            _state.update { it.copy(pushTestRunning = false, pushMessage = message) }
            // A dead token the send found is gone now, which changes the device count.
            loadPushStatus()
        }
    }

    // The name the person gave this phone ("Nathan's Pixel"), which is what they'd recognise in
    // the server's device list; the model name when there isn't one.
    private fun deviceName(): String =
        runCatching {
            android.provider.Settings.Global.getString(getApplication<Application>().contentResolver, android.provider.Settings.Global.DEVICE_NAME)
        }.getOrNull()?.takeIf(String::isNotBlank)
            ?: android.os.Build.MODEL.ifBlank { "Android device" }

    suspend fun loadImage(path: String): Bitmap? = repository.loadImage(path)

    fun absoluteUrl(path: String): String? = repository.absoluteUrl(path)

    fun mediaHeaders(): Map<String, String> = repository.mediaHeaders()

    // ---------------- Music & Podcasts ----------------

    private fun setAudioEnabled(enabled: AudioEnabled) {
        audio.setEnabled(enabled)
        _state.update { it.copy(musicEnabled = enabled.music, podcastsEnabled = enabled.podcasts) }
    }

    // Settings saved a section that might have switched a tab on or off.
    fun refreshAudioEnabled() {
        viewModelScope.launch { runCatching { audio.api.enabled() }.onSuccess(::setAudioEnabled) }
    }

    // ---------------- Movies & TV ----------------

    private fun setMoviesEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(MOVIES_ENABLED_KEY, enabled).apply()
        _state.update { it.copy(moviesEnabled = enabled) }
    }

    // What this phone can decode, asked of MediaCodecList once: the contract's Android lists
    // minus HEVC / AC-3 / E-AC-3 when there is no decoder for them, so the server converts
    // rather than sending a stream that plays silent or black.
    private val mediaCodecs: Pair<String, String> by lazy {
        runCatching {
            val decoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filterNot { it.isEncoder }
            fun has(mime: String) = decoders.any { info -> info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
            MediaApi.mediaCodecs(
                hasHevc = has(MediaFormat.MIMETYPE_VIDEO_HEVC),
                hasAc3 = has(MediaFormat.MIMETYPE_AUDIO_AC3),
                hasEac3 = has(MediaFormat.MIMETYPE_AUDIO_EAC3),
            )
        }.getOrDefault(MediaApi.VIDEO_CODECS to MediaApi.AUDIO_CODECS)
    }

    suspend fun loadImage(path: String, maxWidth: Int): Bitmap? = repository.loadImage(path, maxWidth)

    suspend fun mediaStatus(): MediaStatus = repository.mediaStatus()

    suspend fun mediaHome(): MediaHome = repository.mediaHome()

    suspend fun mediaItems(
        kind: String?,
        query: String?,
        genre: String?,
        sort: String,
        order: String,
        unwatched: Boolean,
        offset: Int,
        limit: Int = MediaApi.PAGE_SIZE,
        list: Boolean = false,
    ): MediaItemsPage = repository.mediaItems(kind, query, genre, sort, order, unwatched, offset, limit, list)

    suspend fun mediaRandom(): MediaItemSummary = repository.mediaRandom()

    suspend fun mediaItem(id: String): MediaItemDetail = repository.mediaItem(id)

    // Bumped when a title leaves the library, so the Movies tab's Home and grids load again and
    // its poster is gone when the user lands back there.
    private val _mediaLibraryVersion = MutableStateFlow(0)
    val mediaLibraryVersion: StateFlow<Int> = _mediaLibraryVersion.asStateFlow()

    suspend fun deleteMediaItem(id: String) {
        repository.deleteMediaItem(id)
        _mediaLibraryVersion.value++
    }

    suspend fun mediaPlayback(id: String, start: Double?): MediaPlayback =
        repository.mediaPlayback(id, start, mediaCodecs.first, mediaCodecs.second)

    suspend fun reportMediaProgress(id: String, positionSeconds: Double, durationSeconds: Double?): MediaProgress? =
        repository.reportMediaProgress(id, positionSeconds, durationSeconds)

    // Fire and forget, on this ViewModel's scope rather than the player's, so the report made as
    // the player closes still reaches the server after the player's own scope is gone.
    fun reportMediaProgressInBackground(id: String, positionSeconds: Double, durationSeconds: Double?) {
        viewModelScope.launch {
            runCatching { repository.reportMediaProgress(id, positionSeconds, durationSeconds) }
                .onFailure { log("Could not save playback progress: ${readableError(it)}", DiagnosticLevel.NOTICE) }
        }
    }

    suspend fun setMediaWatched(id: String, watched: Boolean): MediaProgress? = repository.setMediaWatched(id, watched)

    suspend fun setMediaInList(id: String, inList: Boolean): Boolean = repository.setMediaInList(id, inList)

    suspend fun setMediaSeasonWatched(showId: String, season: Int, watched: Boolean) =
        repository.setMediaSeasonWatched(showId, season, watched)

    // Library admin - Settings -> Movies & TV libraries.
    suspend fun mediaLibraries(): List<MediaLibrary> = repository.mediaLibraries()

    suspend fun saveMediaLibrary(id: String?, input: MediaLibraryInput): MediaLibrary = repository.saveMediaLibrary(id, input)

    suspend fun deleteMediaLibrary(id: String) = repository.deleteMediaLibrary(id)

    suspend fun scanMediaLibrary(id: String) = repository.scanMediaLibrary(id)

    suspend fun scanAllMedia() = repository.scanAllMedia()

    // `base` is /api/media for Movies & TV and /api/audio for Music & Podcasts: the same picker
    // and the same saved sign-ins behind both (MUSIC_AND_PODCASTS.md §1).
    suspend fun mediaBrowse(path: String?, base: String = MediaApi.MEDIA_ROUTES): MediaBrowseListing =
        repository.mediaBrowse(path, base)

    suspend fun mediaCreateFolder(parent: String, name: String, base: String = MediaApi.MEDIA_ROUTES): MediaBrowseListing =
        repository.mediaCreateFolder(parent, name, base)

    suspend fun mediaNetworkComputers(base: String = MediaApi.MEDIA_ROUTES): List<MediaNetworkComputer> =
        repository.mediaNetworkComputers(base)

    suspend fun saveMediaNetworkComputer(id: String?, input: MediaNetworkSignInInput, base: String = MediaApi.MEDIA_ROUTES): MediaNetworkSignInResult =
        repository.saveMediaNetworkComputer(id, input, base)

    suspend fun deleteMediaNetworkComputer(id: String, base: String = MediaApi.MEDIA_ROUTES) =
        repository.deleteMediaNetworkComputer(id, base)

    suspend fun discoverMediaNetworkComputers(base: String = MediaApi.MEDIA_ROUTES): List<MediaDiscoveredComputer> =
        repository.discoverMediaNetworkComputers(base)

    // Movie downloads ("+ Add" on the Movies tab) - core/docs/MOVIE_DOWNLOADS.md. Null status
    // means the feature is off or the server predates it.
    suspend fun mediaDownloadStatus(): com.reelhouse.android.data.MediaDownloadStatus? = repository.mediaDownloadStatus()

    suspend fun mediaDownloadLookup(query: String, kind: String) = repository.mediaDownloadLookup(query, kind)

    suspend fun mediaDownloadShow(tmdbId: Long) = repository.mediaDownloadShow(tmdbId)

    suspend fun startMediaReleaseSearch(input: com.reelhouse.android.data.MediaReleaseSearchInput) =
        repository.startMediaReleaseSearch(input)

    suspend fun mediaReleaseSearch(id: String) = repository.mediaReleaseSearch(id)

    suspend fun startMediaDownload(searchId: String, releaseId: String, replace: Boolean? = null) =
        repository.startMediaDownload(searchId, releaseId, replace = replace)

    suspend fun mediaDownloads() = repository.mediaDownloads()

    // "Import a list" on Movies ("movies") and Music ("music") - same server and session.
    fun mediaImportApi(kind: String) = com.reelhouse.android.data.MediaImportApi(kind) { method, path, query, body, contentType, timeout ->
        repository.rawRequest(method, path, query, body, contentType, timeout)
    }

    suspend fun mediaDownload(id: String) = repository.mediaDownload(id)

    suspend fun deleteMediaDownload(id: String) = repository.deleteMediaDownload(id)

    suspend fun retryMediaDownload(id: String) = repository.retryMediaDownload(id)

    suspend fun testMediaDownloadVpn() = repository.testMediaDownloadVpn()

    suspend fun mediaDownloadSites() = repository.mediaDownloadSites()

    suspend fun mediaDownloadSiteCatalog(query: String) = repository.mediaDownloadSiteCatalog(query)

    suspend fun addMediaDownloadSite(definition: String, fields: org.json.JSONObject) =
        repository.addMediaDownloadSite(definition, fields)

    suspend fun setMediaDownloadSiteEnabled(id: String, enabled: Boolean) = repository.setMediaDownloadSiteEnabled(id, enabled)

    suspend fun deleteMediaDownloadSite(id: String) = repository.deleteMediaDownloadSite(id)

    suspend fun settingsSchema(): List<SettingsSection> = repository.settingsSchema()

    suspend fun settingsSnapshot(): org.json.JSONObject = repository.settingsSnapshot()

    suspend fun settingsSectionData(endpoint: String): org.json.JSONObject =
        repository.settingsSectionData(endpoint)

    // Whether the server settings list shows advanced sections. Remembered per device, like the
    // web dashboard's own toggle - and purely a display preference: every setting is reachable
    // either way, and searching ignores it entirely.
    var showAdvancedSettings: Boolean
        get() = preferences.getBoolean(ADVANCED_SETTINGS_KEY, false)
        set(value) {
            preferences.edit().putBoolean(ADVANCED_SETTINGS_KEY, value).apply()
        }

    suspend fun saveSettingsSection(endpoint: String, body: org.json.JSONObject): Boolean =
        repository.saveSettingsSection(endpoint, body).also {
            // MUSIC and PODCASTS each carry an `enabled` switch that adds or removes a tab.
            if (endpoint.endsWith("/music") || endpoint.endsWith("/podcasts")) refreshAudioEnabled()
        }

    suspend fun settingsLookup(lookup: SettingsLookup, query: String): List<SettingsLookupCandidate> =
        repository.settingsLookup(lookup, query)

    suspend fun settingsOptions(source: SettingsOptionsSource): List<SettingsFieldOption> =
        repository.settingsOptions(source)

    // String? rather than an inferred type: what an action reports back is part of this screen's
    // contract now that the test sends have something to say, and the neighbours here spell
    // theirs out for the same reason.
    suspend fun runSettingsAction(action: SettingsAction): String? = repository.runSettingsAction(action)

    // Both of these change whether the whole app needs a login, so each re-reads the auth status
    // rather than assuming it landed - the sign-in gate reads the same field.
    suspend fun enableDashboardLogin(username: String, password: String) {
        repository.enableDashboardLogin(username, password)
        refreshAuthStatus()
    }

    suspend fun disableDashboardLogin() {
        repository.disableDashboardLogin()
        refreshAuthStatus()
    }

    suspend fun refreshAuthStatus() {
        val auth = runCatching { repository.authStatus() }.getOrNull()
        _state.update { it.copy(authStatus = auth) }
    }

    suspend fun restartServer(service: String) = repository.restartServer(service)

    suspend fun refreshAccounts() {
        val value = repository.accounts()
        _state.update { it.copy(accounts = value) }
    }

    suspend fun createAccount(username: String, password: String, role: String, displayName: String?): Account {
        val created = repository.createAccount(username, password, role, displayName)
        _state.update { it.copy(accounts = it.accounts + created) }
        return created
    }

    suspend fun updateAccountRole(account: Account, role: String) {
        repository.updateAccountRole(account.id, role)
        _state.update { current ->
            current.copy(accounts = current.accounts.map { if (it.id == account.id) it.copy(role = role) else it })
        }
    }

    suspend fun resetAccountPassword(account: Account, newPassword: String) {
        repository.resetAccountPassword(account.id, newPassword)
    }

    // Optimistic remove with rollback on failure, rather than a full refetch. A failure here is
    // expected and common (server refuses to delete the last remaining admin account), so the
    // rollback matters.
    suspend fun deleteAccount(account: Account) {
        val previous = _state.value.accounts
        _state.update { it.copy(accounts = it.accounts.filterNot { existing -> existing.id == account.id }) }
        try {
            repository.deleteAccount(account.id)
        } catch (error: Exception) {
            _state.update { it.copy(accounts = previous) }
            throw error
        }
    }

    suspend fun changeMyPassword(currentPassword: String, newPassword: String) {
        repository.changeMyPassword(currentPassword, newPassword)
    }

    fun clearDiagnostics() {
        _state.update { it.copy(diagnostics = emptyList()) }
    }

    private fun log(message: String, level: DiagnosticLevel) {
        val entry = DiagnosticEntry(
            id = logSequence.incrementAndGet(),
            timestamp = Instant.now(),
            level = level,
            message = message,
        )
        _state.update { current ->
            current.copy(diagnostics = (listOf(entry) + current.diagnostics).take(100))
        }
        android.util.Log.d("ReelHouse", "[$level] $message")
    }

    private fun readableError(error: Throwable): String =
        error.message?.takeIf(String::isNotBlank) ?: "Could not connect to ReelHouse."

    companion object {
        const val IMPOSTOR_MESSAGE =
            "Something at this address isn't your ReelHouse server - its certificate wasn't " +
                "issued by your server. Nothing was sent to it. If you're away from home, that's " +
                "expected: use the remote address. If you reinstalled the server, save its address " +
                "again in Settings."

        const val SERVER_URL_KEY = "server_url"
        const val REMOTE_SERVER_URL_KEY = "remote_server_url"
        private const val MOVIES_ENABLED_KEY = "movies_enabled_last_known"
        private const val ADVANCED_SETTINGS_KEY = "settings_show_advanced"
    }
}
