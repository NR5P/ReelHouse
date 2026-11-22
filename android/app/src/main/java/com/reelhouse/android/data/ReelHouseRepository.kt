package com.reelhouse.android.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpCookie
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.cert.CertPathValidatorException
import java.security.cert.CertificateException
import java.time.Instant
import javax.net.ssl.SSLHandshakeException

// The outcome of a reachability probe. CERTIFICATE_UNTRUSTED is split out from UNREACHABLE because
// it is the one failure with somewhere else to go - the same host's plain-HTTP port.
enum class Reachability {
    REACHABLE,
    CERTIFICATE_UNTRUSTED,
    UNREACHABLE,
}

class ReelHouseRepository(
    context: Context,
    private val logger: (String, DiagnosticLevel) -> Unit,
) {
    @Volatile
    var baseUrl: String = ""

    private val cookieManager = CookieManager(null, CookiePolicy.ACCEPT_ALL)
    private val sessionCookieStore = SessionCookieStore(context.applicationContext)

    // Set by storeCookies when a response handed over a cookie the jar will never give back.
    // Read by login(), where it is the whole difference between "wrong password" and "right
    // password, unusable session" - two failures that otherwise look identical from the outside.
    @Volatile
    private var droppedSecureCookie = false
    private val imageCache = object : LruCache<String, Bitmap>(
        minOf(32 * 1024, (Runtime.getRuntime().maxMemory() / 1024 / 8).toInt()),
    ) {
        override fun sizeOf(key: String, value: Bitmap): Int =
            (value.byteCount / 1024).coerceAtLeast(1)
    }

    suspend fun authStatus(): AuthStatus = withContext(Dispatchers.IO) {
        val json = JSONObject(request("/api/auth/status"))
        AuthStatus(
            enabled = json.optBoolean("enabled"),
            configured = json.optBoolean("configured"),
            authenticated = json.optBoolean("authenticated"),
            username = json.nullableString("username"),
            role = json.nullableString("role"),
        )
    }

    // Unauthenticated on the server side, so this is readable at the login screen too - which is
    // where knowing the server is too old is arguably most useful. A server old enough to predate
    // version stamping answers this endpoint without a "build" object at all, which is exactly the
    // null that ServerCompatibility.evaluate reads as "too old".
    suspend fun serverHealth(): ServerBuild? = withContext(Dispatchers.IO) {
        val build = JSONObject(request("/api/health")).optJSONObject("build")
            ?: return@withContext null
        ServerBuild(
            version = build.optString("version"),
            commit = build.optString("commit"),
            isDirty = build.optBoolean("isDirty"),
            display = build.optString("display"),
        )
    }

    // ---------------- Movies & TV (core/docs/MOVIES.md) ----------------

    // Answers even when the section is off; a 404 from an older server throws, which the caller
    // reads as "off" too.
    suspend fun mediaEnabled(): Boolean = withContext(Dispatchers.IO) {
        JSONObject(request("/api/media/enabled")).optBoolean("enabled")
    }

    suspend fun mediaStatus(): MediaStatus = withContext(Dispatchers.IO) {
        parseMediaStatus(JSONObject(request("/api/media/status")))
    }

    suspend fun mediaHome(): MediaHome = withContext(Dispatchers.IO) {
        parseMediaHome(JSONObject(request("/api/media/home")))
    }

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
    ): MediaItemsPage = withContext(Dispatchers.IO) {
        parseMediaItemsPage(JSONObject(request(MediaApi.itemsPath(kind, query, genre, sort, order, unwatched, offset, limit, list))))
    }

    // "Surprise me". A 404 when nothing matches throws with the server's own "Nothing in the
    // library matches that yet." as the message.
    suspend fun mediaRandom(): MediaItemSummary = withContext(Dispatchers.IO) {
        parseMediaItem(JSONObject(request(MediaApi.RANDOM_PATH)))
    }

    suspend fun mediaItem(id: String): MediaItemDetail = withContext(Dispatchers.IO) {
        parseMediaItemDetail(JSONObject(request(MediaApi.itemPath(id))))
    }

    // Admin: deletes a movie's files from the server's disk and forgets it (204). A 400 (a show,
    // or a movie on another computer's share) or 404 throws with the server's message.
    suspend fun deleteMediaItem(id: String): Unit = withContext(Dispatchers.IO) {
        request(MediaApi.itemPath(id), method = "DELETE")
        Unit
    }

    suspend fun mediaPlayback(id: String, start: Double?, video: String, audio: String): MediaPlayback =
        withContext(Dispatchers.IO) {
            parseMediaPlayback(JSONObject(request(MediaApi.playbackPath(id, start, video, audio))))
        }

    suspend fun reportMediaProgress(id: String, positionSeconds: Double, durationSeconds: Double?): MediaProgress? =
        withContext(Dispatchers.IO) {
            val body = JSONObject().put("positionSeconds", positionSeconds)
            durationSeconds?.let { body.put("durationSeconds", it) }
            val text = request(MediaApi.itemPath(id) + "/progress", method = "POST", body = body.toString())
            runCatching { parseMediaProgress(JSONObject(text)) }.getOrNull()
        }

    suspend fun setMediaWatched(id: String, watched: Boolean): MediaProgress? = withContext(Dispatchers.IO) {
        val text = request(
            MediaApi.itemPath(id) + "/watched",
            method = "POST",
            body = JSONObject().put("watched", watched).toString(),
        )
        runCatching { parseMediaProgress(JSONObject(text)) }.getOrNull()
    }

    // Adds to (or removes from) this account's My List. Returns whether it is on the list now.
    suspend fun setMediaInList(id: String, inList: Boolean): Boolean = withContext(Dispatchers.IO) {
        val text = request(
            MediaApi.listPath(id),
            method = "POST",
            body = JSONObject().put("inList", inList).toString(),
        )
        runCatching { parseMediaListResult(JSONObject(text), id).second }.getOrDefault(inList)
    }

    suspend fun setMediaSeasonWatched(showId: String, season: Int, watched: Boolean): Unit = withContext(Dispatchers.IO) {
        request(
            MediaApi.seasonWatchedPath(showId, season),
            method = "POST",
            body = JSONObject().put("watched", watched).toString(),
        )
        Unit
    }

    // ---- Library admin (everything below but mediaLibraries() is Admin-only). With the section
    // off each of these is a 404 whose `error` says so, which request() hands back as the
    // exception message.

    suspend fun mediaLibraries(): List<MediaLibrary> = withContext(Dispatchers.IO) {
        parseMediaLibraries(JSONArray(request("/api/media/libraries")))
    }

    // Creates when `id` is null. A 400 carries every problem in `errors`, joined into the message.
    suspend fun saveMediaLibrary(id: String?, input: MediaLibraryInput): MediaLibrary = withContext(Dispatchers.IO) {
        val path = if (id == null) "/api/media/libraries" else MediaApi.libraryPath(id)
        parseMediaLibrary(JSONObject(request(path, method = if (id == null) "POST" else "PUT", body = input.toJson().toString())))
    }

    suspend fun deleteMediaLibrary(id: String): Unit = withContext(Dispatchers.IO) {
        request(MediaApi.libraryPath(id), method = "DELETE")
        Unit
    }

    // 202; a 409 (a scan is already running) throws with the server's message.
    suspend fun scanMediaLibrary(id: String): Unit = withContext(Dispatchers.IO) {
        request(MediaApi.libraryPath(id) + "/scan", method = "POST")
        Unit
    }

    suspend fun scanAllMedia(): Unit = withContext(Dispatchers.IO) {
        request("/api/media/scan", method = "POST")
        Unit
    }

    // Always a 200 on a working server; a folder that can't be opened comes back with `error`.
    // Browsing a computer can take a while (name lookup, sign-in), hence the longer timeout.
    suspend fun mediaBrowse(path: String?, base: String = MediaApi.MEDIA_ROUTES): MediaBrowseListing = withContext(Dispatchers.IO) {
        val (status, body) = requestWithStatus(MediaApi.browsePath(path, base), method = "GET", body = null, readTimeoutMillis = 60_000)
        if (status !in 200..299) {
            throw ReelHouseApiException(
                status,
                parseServerError(body) ?: if (status == 401) "This server requires you to sign in." else "Server request failed (HTTP $status).",
            )
        }
        parseMediaBrowseListing(JSONObject(body))
    }

    // A 400 carries the server's reason (bad name, read-only share, ...) as the message.
    suspend fun mediaCreateFolder(parent: String, name: String, base: String = MediaApi.MEDIA_ROUTES): MediaBrowseListing = withContext(Dispatchers.IO) {
        val (status, body) = requestWithStatus(
            MediaApi.browseFolderPath(base),
            method = "POST",
            body = MediaApi.newFolderBody(parent, name).toString(),
            readTimeoutMillis = 60_000,
        )
        if (status !in 200..299) {
            throw ReelHouseApiException(
                status,
                parseServerError(body) ?: if (status == 401) "This server requires you to sign in." else "Could not make that folder (HTTP $status).",
            )
        }
        parseMediaBrowseListing(JSONObject(body))
    }

    suspend fun mediaNetworkComputers(base: String = MediaApi.MEDIA_ROUTES): List<MediaNetworkComputer> = withContext(Dispatchers.IO) {
        parseMediaNetworkComputers(JSONArray(request("$base/network")))
    }

    // Signs in and saves only if that works (POST, or PUT to update the saved `id`). A refused
    // sign-in is a 400 that throws MediaNetworkSignInException, so the form can stay open.
    suspend fun saveMediaNetworkComputer(id: String?, input: MediaNetworkSignInInput, base: String = MediaApi.MEDIA_ROUTES): MediaNetworkSignInResult =
        withContext(Dispatchers.IO) {
            val (status, body) = requestWithStatus(
                if (id == null) "$base/network" else MediaApi.networkComputerPath(id, base),
                method = if (id == null) "POST" else "PUT",
                body = input.toJson().toString(),
                readTimeoutMillis = 60_000,
            )
            when {
                status in 200..299 -> parseMediaNetworkSignIn(JSONObject(body))
                status == 400 -> throw parseMediaNetworkSignInError(body)
                    ?: MediaNetworkSignInException("Could not sign in to that computer.", needsLogin = true)
                else -> throw ReelHouseApiException(
                    status,
                    parseServerError(body) ?: if (status == 401) "This server requires you to sign in." else "Server request failed (HTTP $status).",
                )
            }
        }

    suspend fun deleteMediaNetworkComputer(id: String, base: String = MediaApi.MEDIA_ROUTES): Unit = withContext(Dispatchers.IO) {
        request(MediaApi.networkComputerPath(id, base), method = "DELETE")
        Unit
    }

    // Takes about three seconds: the server listens for mDNS answers.
    suspend fun discoverMediaNetworkComputers(base: String = MediaApi.MEDIA_ROUTES): List<MediaDiscoveredComputer> = withContext(Dispatchers.IO) {
        val (status, body) = requestWithStatus("$base/network/discover", method = "GET", body = null, readTimeoutMillis = 30_000)
        if (status !in 200..299) {
            throw ReelHouseApiException(status, parseServerError(body) ?: "Server request failed (HTTP $status).")
        }
        parseMediaDiscoveredComputers(JSONArray(body))
    }

    // ---------------- Movie downloads (core/docs/MOVIE_DOWNLOADS.md) ----------------

    // Null when the feature is not there to use: a 404 (turned off, Movies & TV off, or a server
    // older than downloads) hides "+ Add" rather than showing an error.
    suspend fun mediaDownloadStatus(): MediaDownloadStatus? = withContext(Dispatchers.IO) {
        val (status, body) = requestWithStatus(MediaDownloadApi.STATUS_PATH, method = "GET", body = null)
        when {
            status in 200..299 -> runCatching { parseMediaDownloadStatus(JSONObject(body)) }.getOrNull()
            status == 404 -> null
            else -> throw ReelHouseApiException(status, parseServerError(body) ?: "Server request failed (HTTP $status).")
        }
    }

    suspend fun mediaDownloadLookup(query: String, kind: String): MediaLookup = withContext(Dispatchers.IO) {
        parseMediaLookup(JSONObject(request(MediaDownloadApi.lookupPath(query, kind))))
    }

    suspend fun mediaDownloadShow(tmdbId: Long): MediaDownloadShow = withContext(Dispatchers.IO) {
        parseMediaDownloadShow(JSONObject(request(MediaDownloadApi.showPath(tmdbId))))
    }

    // 202 with the search to poll. The first search after idle starts the VPN, so the answer can
    // take a while; the server itself answers quickly and does the waiting in the search.
    suspend fun startMediaReleaseSearch(input: MediaReleaseSearchInput): MediaReleaseSearch = withContext(Dispatchers.IO) {
        parseMediaReleaseSearch(JSONObject(request(MediaDownloadApi.SEARCH_PATH, method = "POST", body = input.toJson().toString())))
    }

    // A 404 once the search has expired (30 minutes) throws with the server's message.
    suspend fun mediaReleaseSearch(id: String): MediaReleaseSearch = withContext(Dispatchers.IO) {
        parseMediaReleaseSearch(JSONObject(request(MediaDownloadApi.searchPath(id))))
    }

    // 201. A 400 (no library of the right kind, or the search expired) throws with its message; a
    // 409 for a movie the library already has throws MediaAlreadyInLibraryException, so the screen
    // can ask and send it again with `replace`.
    suspend fun startMediaDownload(
        searchId: String,
        releaseId: String,
        libraryId: String? = null,
        replace: Boolean? = null,
    ): MediaDownload = withContext(Dispatchers.IO) {
        val body = MediaDownloadApi.grabBody(searchId, releaseId, libraryId, replace).toString()
        val (status, text) = requestWithStatus(MediaDownloadApi.DOWNLOADS_PATH, method = "POST", body = body)
        if (status in 200..299) return@withContext parseMediaDownload(JSONObject(text))
        if (status == 409) parseMediaAlreadyInLibrary(text)?.let { throw it }
        throw ReelHouseApiException(
            status,
            parseServerError(text) ?: if (status == 401) "This server requires you to sign in." else "Server request failed (HTTP $status).",
        )
    }

    suspend fun mediaDownloads(): MediaDownloadList = withContext(Dispatchers.IO) {
        parseMediaDownloadList(JSONObject(request(MediaDownloadApi.DOWNLOADS_PATH)))
    }

    suspend fun mediaDownload(id: String): MediaDownload = withContext(Dispatchers.IO) {
        parseMediaDownload(JSONObject(request(MediaDownloadApi.downloadPath(id))))
    }

    // Cancels an active download (its files are deleted) or removes a finished one from the list.
    suspend fun deleteMediaDownload(id: String): Unit = withContext(Dispatchers.IO) {
        request(MediaDownloadApi.downloadPath(id), method = "DELETE")
        Unit
    }

    // The answer is the requeued download; an older or odd body is not worth failing over.
    suspend fun retryMediaDownload(id: String): MediaDownload? = withContext(Dispatchers.IO) {
        val text = request(MediaDownloadApi.retryPath(id), method = "POST")
        runCatching { parseMediaDownload(JSONObject(text)) }.getOrNull()?.takeIf { it.id.isNotBlank() }
    }

    // The sites routes (Admin) start the VPN services; while they come up the answer is a 503
    // { starting: true }, thrown as MediaDownloadsStartingException so the screen can retry.
    private fun sitesRequest(path: String, method: String = "GET", body: String? = null): String {
        val (status, text) = requestWithStatus(path, method = method, body = body, readTimeoutMillis = 60_000)
        if (status in 200..299) return text
        if (status == 503) parseMediaDownloadsStarting(text)?.let { throw it }
        throw ReelHouseApiException(
            status,
            parseServerError(text) ?: if (status == 401) "This server requires you to sign in." else "Server request failed (HTTP $status).",
        )
    }

    // "Test VPN": starts everything if needed, so it can take up to a minute. ok false is a 200
    // whose message says what is wrong; only a failed request throws.
    suspend fun testMediaDownloadVpn(): MediaVpnTestResult = withContext(Dispatchers.IO) {
        val (status, text) = requestWithStatus(MediaDownloadApi.VPN_TEST_PATH, method = "POST", body = null, readTimeoutMillis = 90_000)
        if (status !in 200..299) {
            throw ReelHouseApiException(
                status,
                parseServerError(text) ?: if (status == 401) "This server requires you to sign in." else "Server request failed (HTTP $status).",
            )
        }
        parseMediaVpnTestResult(JSONObject(text))
    }

    suspend fun mediaDownloadSites(): List<MediaDownloadSite> = withContext(Dispatchers.IO) {
        parseMediaDownloadSites(JSONArray(sitesRequest(MediaDownloadApi.SITES_PATH)))
    }

    suspend fun mediaDownloadSiteCatalog(query: String): List<MediaSiteDefinition> = withContext(Dispatchers.IO) {
        parseMediaSiteCatalog(JSONArray(sitesRequest(MediaDownloadApi.catalogPath(query))))
    }

    // Prowlarr tests the site first; a failure is a 400 whose message says why.
    suspend fun addMediaDownloadSite(definition: String, fields: JSONObject): MediaDownloadSite = withContext(Dispatchers.IO) {
        val text = sitesRequest(MediaDownloadApi.SITES_PATH, method = "POST", body = MediaDownloadApi.addSiteBody(definition, fields).toString())
        runCatching { parseMediaDownloadSite(JSONObject(text)) }.getOrElse { MediaDownloadSite(id = "", name = definition) }
    }

    suspend fun setMediaDownloadSiteEnabled(id: String, enabled: Boolean): Unit = withContext(Dispatchers.IO) {
        sitesRequest(MediaDownloadApi.sitePath(id), method = "PUT", body = JSONObject().put("enabled", enabled).toString())
        Unit
    }

    suspend fun deleteMediaDownloadSite(id: String): Unit = withContext(Dispatchers.IO) {
        sitesRequest(MediaDownloadApi.sitePath(id), method = "DELETE")
        Unit
    }

    // Turning the dashboard's login requirement on creates the first admin account in the same
    // step - there is deliberately no way to demand a login nobody can satisfy.
    suspend fun enableDashboardLogin(username: String, password: String): Unit = withContext(Dispatchers.IO) {
        request(
            "/api/auth/enable",
            method = "POST",
            body = JSONObject().put("username", username).put("password", password).toString(),
        )
        Unit
    }

    suspend fun disableDashboardLogin(): Unit = withContext(Dispatchers.IO) {
        request("/api/auth/disable", method = "POST")
        Unit
    }

    suspend fun accounts(): List<Account> = withContext(Dispatchers.IO) {
        val array = JSONArray(request("/api/accounts"))
        buildList {
            for (index in 0 until array.length()) add(parseAccount(array.getJSONObject(index)))
        }
    }

    suspend fun createAccount(
        username: String,
        password: String,
        role: String,
        displayName: String?,
    ): Account = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("username", username)
            .put("password", password)
            .put("role", role)
            .put("displayName", displayName)
        parseAccount(JSONObject(request("/api/accounts", method = "POST", body = body.toString())))
    }

    suspend fun updateAccountRole(id: String, role: String) = withContext(Dispatchers.IO) {
        val body = JSONObject().put("role", role)
        request("/api/accounts/${queryValue(id)}/role", method = "PUT", body = body.toString())
    }

    suspend fun resetAccountPassword(id: String, newPassword: String) = withContext(Dispatchers.IO) {
        val body = JSONObject().put("newPassword", newPassword)
        request("/api/accounts/${queryValue(id)}/reset-password", method = "POST", body = body.toString())
    }

    suspend fun deleteAccount(id: String) = withContext(Dispatchers.IO) {
        request("/api/accounts/${queryValue(id)}", method = "DELETE")
    }

    // The server deliberately leaves the current session alone (doesn't invalidate it) - no
    // separate re-login needed here, the existing cookie just keeps working.
    suspend fun changeMyPassword(currentPassword: String, newPassword: String) = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("currentPassword", currentPassword)
            .put("newPassword", newPassword)
        request("/api/accounts/change-password", method = "POST", body = body.toString())
    }

    // ---- Push notifications (push/PushNotifications). Each needs the signed-in session: the
    // server files the device under whoever is signed in. ----

    suspend fun pushStatus(): PushStatus = withContext(Dispatchers.IO) {
        parsePushStatus(JSONObject(request("/api/push/status")))
    }

    suspend fun registerPushDevice(token: String, deviceName: String) = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("platform", "android")
            .put("token", token)
            .put("deviceName", deviceName)
            .put("appVariant", "android")
        request("/api/push/devices", method = "POST", body = body.toString())
    }

    suspend fun unregisterPushDevice(token: String) = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("platform", "android")
            .put("token", token)
        request("/api/push/devices/unregister", method = "POST", body = body.toString())
    }

    // A 400 (push off, nothing registered) arrives as a ReelHouseApiException carrying the
    // server's own "error" text, which is what Settings shows.
    suspend fun testPushNotification(): PushDeliveryReport = withContext(Dispatchers.IO) {
        parsePushDeliveryReport(JSONObject(request("/api/push/test", method = "POST")))
    }

    suspend fun login(username: String, password: String) = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("username", username)
            .put("password", password)
            .toString()
        droppedSecureCookie = false
        request("/api/auth/login", method = "POST", body = body)
        // HTTP 200 here proves the password was right, not that the session survived. When it
        // didn't, every later request comes back 401 and the app reports the server's own wording
        // for that - "This server requires you to sign in." - directly under a login that just
        // succeeded, which reads as a rejected password and sends people off to reset one that
        // was never wrong. Fail here instead, while the actual cause is still known.
        if (droppedSecureCookie) throw IOException(secureCookieRejectedMessage())
    }

    private fun secureCookieRejectedMessage(): String {
        val secureAddress = normalizedBaseUrl()?.let(ServerAddress::httpsEquivalent)
        return "Signed in, but the server issued a secure session cookie, which cannot be sent " +
            "back over an unencrypted http:// address - so every request after this one would be " +
            "rejected. " + if (secureAddress != null) {
            "Change this server's address to $secureAddress and sign in again."
        } else {
            "Use the https:// form of this server's address and sign in again."
        }
    }

    suspend fun logout() = withContext(Dispatchers.IO) {
        request("/api/auth/logout", method = "POST")
    }

    fun absoluteUrl(path: String): String? {
        val root = normalizedBaseUrl() ?: return null
        return "$root/${path.trimStart('/')}"
    }

    // ExoPlayer opens clip and HLS URLs on its own HTTP stack, which shares nothing with
    // openConnection - so the session has to be handed to it explicitly or every media request
    // comes back 401 while the rest of the app looks perfectly signed in.
    fun mediaHeaders(): Map<String, String> {
        val url = runCatching { URL(normalizedBaseUrl() ?: return emptyMap()) }.getOrNull()
            ?: return emptyMap()
        val cookie = cookieHeader(url) ?: return emptyMap()
        return mapOf("Cookie" to cookie)
    }

    suspend fun loadImage(path: String): Bitmap? = withContext(Dispatchers.IO) {
        val urlString = absoluteUrl(path) ?: return@withContext null
        imageCache.get(urlString)?.let { return@withContext it }

        val connection = openConnection(URL(urlString))
        try {
            connection.requestMethod = "GET"
            connection.connect()
            storeCookies(connection)
            if (connection.responseCode !in 200..299) return@withContext null
            val bitmap = connection.inputStream.use(BitmapFactory::decodeStream)
            if (bitmap != null) imageCache.put(urlString, bitmap)
            bitmap
        } catch (error: Exception) {
            logger("Image request failed: ${error.message ?: error.javaClass.simpleName}", DiagnosticLevel.NOTICE)
            null
        } finally {
            connection.disconnect()
        }
    }

    // Artwork for the Movies tab: downsampled on decode to about maxWidth pixels, since TMDB
    // posters and backdrops arrive far larger than any tile draws them. Cached under its own key
    // per width, so a poster in a grid and the same poster on a detail screen don't collide.
    //
    // Movie downloads hand out TMDB's own poster URLs (https://image.tmdb.org/...) rather than
    // server paths; those are fetched as they are, without the session cookie.
    suspend fun loadImage(path: String, maxWidth: Int): Bitmap? = withContext(Dispatchers.IO) {
        val external = path.startsWith("https://", ignoreCase = true) || path.startsWith("http://", ignoreCase = true)
        val urlString = if (external) path else absoluteUrl(path) ?: return@withContext null
        val key = "$urlString#w$maxWidth"
        imageCache.get(key)?.let { return@withContext it }

        val connection = if (external) {
            (URL(urlString).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 30_000
            }
        } else {
            openConnection(URL(urlString))
        }
        try {
            connection.requestMethod = "GET"
            connection.connect()
            if (!external) storeCookies(connection)
            if (connection.responseCode !in 200..299) return@withContext null
            val bytes = connection.inputStream.use { it.readBytes() }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val options = BitmapFactory.Options().apply {
                inSampleSize = MediaPlaybackMath.imageSampleSize(bounds.outWidth, maxWidth)
            }
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            if (bitmap != null) imageCache.put(key, bitmap)
            bitmap
        } catch (error: Exception) {
            logger("Artwork request failed: ${error.message ?: error.javaClass.simpleName}", DiagnosticLevel.NOTICE)
            null
        } finally {
            connection.disconnect()
        }
    }

    fun resetSession() {
        imageCache.evictAll()
        logger("Created a fresh network session", DiagnosticLevel.INFO)
    }

    // Used to decide between the local and remote server addresses before a real connect - any
    // HTTP response counts as "reachable" (even a 401 or 500), since the point is just to detect
    // whether the host is reachable at all. Opens its own connection with a short timeout rather
    // than going through openConnection()/the shared baseUrl, so the real-request 15s/30s
    // timeouts used elsewhere stay untouched.
    suspend fun probe(urlString: String, timeoutMs: Int = 2500): Reachability =
        withContext(Dispatchers.IO) {
            val trimmed = urlString.trim().trimEnd('/')
            if (trimmed.isBlank()) return@withContext Reachability.UNREACHABLE
            val url = runCatching { URL("$trimmed/api/auth/status") }.getOrNull()
                ?: return@withContext Reachability.UNREACHABLE
            var connection: HttpURLConnection? = null
            try {
                connection = url.openConnection() as HttpURLConnection
                connection.connectTimeout = timeoutMs
                connection.readTimeout = timeoutMs
                connection.responseCode
                Reachability.REACHABLE
            } catch (error: IOException) {
                if (isCertificateTrustFailure(error)) Reachability.CERTIFICATE_UNTRUSTED
                else Reachability.UNREACHABLE
            } finally {
                connection?.disconnect()
            }
        }

    // A certificate this device won't trust is worth telling apart from a host that isn't there:
    // the first has a plain-HTTP port worth retrying, the second doesn't. ReelHouse signs its
    // certificate with a CA it generates on first run (DEPLOYMENT.md 14a), so a stock Android
    // device rejects the local https:// address until that CA is installed - and to a bare
    // reachability probe that looks exactly like being on someone else's network.
    private fun isCertificateTrustFailure(error: Throwable): Boolean {
        val seen = mutableSetOf<Throwable>()
        var current: Throwable? = error
        while (current != null && seen.add(current)) {
            if (current is CertificateException || current is CertPathValidatorException) return true
            current = current.cause
        }
        return error is SSLHandshakeException
    }

    // Drops whatever session this jar would send to `urlString` - in memory and on disk - so a
    // server that hasn't proved who it is (see ServerIdentity) gets none of it. Non-Secure cookies
    // are scoped to the host, not the port or scheme, so the plain-HTTP fallback address would
    // otherwise carry a session earned anywhere on that IP.
    fun forgetSession(urlString: String) {
        val url = ServerAddress.normalize(urlString)?.let { runCatching { URL(it) }.getOrNull() } ?: return
        runCatching {
            val uri = url.toURI()
            cookieManager.cookieStore.get(uri).forEach { cookieManager.cookieStore.remove(uri, it) }
        }
        runCatching { sessionCookieStore.clear(url) }
        imageCache.evictAll()
    }

    fun clearAuthenticationSession() {
        cookieManager.cookieStore.removeAll()
        normalizedBaseUrl()?.let { runCatching { sessionCookieStore.clear(URL(it)) } }
        imageCache.evictAll()
    }

    // ---------------- Server settings (schema-driven, Admin-only server-side) ----------------

    suspend fun settingsSchema(): List<SettingsSection> = withContext(Dispatchers.IO) {
        val array = JSONArray(request("/api/settings/schema"))
        buildList {
            for (index in 0 until array.length()) add(parseSettingsSection(array.getJSONObject(index)))
        }
    }

    // The full settings snapshot, kept as raw JSON on purpose: its shape is described by the
    // schema above, and hard-coding it here is exactly what the schema exists to avoid. Secrets
    // arrive masked (••••••••) and are sent back unchanged to mean "keep the stored value".
    suspend fun settingsSnapshot(): JSONObject = withContext(Dispatchers.IO) {
        JSONObject(request("/api/settings"))
    }

    // The values for a section that isn't in the bulk snapshot, fetched from the dataEndpoint the
    // schema gives it. Only INTERNET EXPOSED MODE needs this - it configures the dashboard
    // project's own Kestrel binding and so lives in a different settings file - but nothing here
    // knows that: the section says where its values are and this fetches them.
    suspend fun settingsSectionData(endpoint: String): JSONObject = withContext(Dispatchers.IO) {
        JSONObject(request(endpoint))
    }

    // Returns whether the saved section needs a restart to take effect (the Urls section).
    suspend fun saveSettingsSection(endpoint: String, body: JSONObject): Boolean = withContext(Dispatchers.IO) {
        val json = JSONObject(request(endpoint, method = "PUT", body = body.toString()))
        json.optBoolean("restartRequired")
    }

    // Runs a settings field's lookup (SettingsLookup). The endpoint and what the values mean both
    // come from the schema, so this stays one method however many fields grow one.
    suspend fun settingsLookup(lookup: SettingsLookup, query: String): List<SettingsLookupCandidate> =
        withContext(Dispatchers.IO) {
            val json = JSONObject(request("${lookup.endpoint}?query=${queryValue(query)}"))
            val results = json.optJSONArray("results") ?: JSONArray()
            buildList {
                for (index in 0 until results.length()) {
                    val candidate = results.getJSONObject(index)
                    val values = candidate.optJSONObject("values") ?: JSONObject()
                    add(
                        SettingsLookupCandidate(
                            label = candidate.optString("label"),
                            values = buildMap {
                                for (key in values.keys()) put(key, values.get(key))
                            },
                        ),
                    )
                }
            }
        }

    // Fetches the values a settings field can hold (SettingsOptionsSource). Same shape as
    // settingsLookup above and for the same reason: the endpoint comes from the schema, so one
    // method serves however many fields grow a list.
    suspend fun settingsOptions(source: SettingsOptionsSource): List<SettingsFieldOption> =
        withContext(Dispatchers.IO) {
            val json = JSONObject(request(source.endpoint))
            val options = json.optJSONArray("options") ?: JSONArray()
            buildList {
                for (index in 0 until options.length()) {
                    val option = options.getJSONObject(index)
                    add(SettingsFieldOption(option.getString("value"), option.optString("label")))
                }
            }
        }

    // Returns whatever the action had to say for itself, or null when it had nothing. The test
    // sends report which address the mail actually went to; the setup reset answers with a body of
    // a different shape entirely, and an unreadable answer to a call that succeeded still means it
    // succeeded - a failure has already thrown by here, carrying the server's own message.
    suspend fun runSettingsAction(action: SettingsAction): String? = withContext(Dispatchers.IO) {
        val body = request(action.endpoint, method = action.method)
        runCatching { JSONObject(body).optString("detail").ifEmpty { null } }.getOrNull()
    }

    // service is "bridge" or "dashboard". The server answers 202 and restarts only when running
    // under a supervisor (systemd etc.); otherwise it refuses with an explanation that surfaces
    // through ReelHouseApiException like any other server error message.
    suspend fun restartServer(service: String): Unit = withContext(Dispatchers.IO) {
        request(
            "/api/system/restart",
            method = "POST",
            body = JSONObject().put("service", service).toString(),
        )
        Unit
    }

    private fun parseSettingsSection(json: JSONObject): SettingsSection {
        val fieldsArray = json.getJSONArray("fields")
        return SettingsSection(
            key = json.getString("key"),
            title = json.getString("title"),
            endpoint = json.getString("endpoint"),
            description = json.optString("description"),
            fields = buildList {
                for (index in 0 until fieldsArray.length()) {
                    val field = fieldsArray.getJSONObject(index)
                    add(
                        SettingsField(
                            name = field.getString("name"),
                            label = field.getString("label"),
                            type = field.getString("type"),
                            tip = field.optString("tip"),
                            options = field.optJSONArray("options")?.let { options ->
                                buildList {
                                    for (o in 0 until options.length()) {
                                        val option = options.getJSONObject(o)
                                        add(SettingsFieldOption(option.getString("value"), option.getString("label")))
                                    }
                                }
                            } ?: emptyList(),
                            // has() rather than optDouble's own default: 0 is a legal bound on
                            // plenty of these fields, so an absent min must stay null and not
                            // become a floor of zero.
                            min = if (field.has("min") && !field.isNull("min")) field.getDouble("min") else null,
                            max = if (field.has("max") && !field.isNull("max")) field.getDouble("max") else null,
                            integer = if (field.has("integer")) field.getBoolean("integer") else null,
                            lookup = field.optJSONObject("lookup")?.let {
                                SettingsLookup(
                                    label = it.getString("label"),
                                    tip = it.optString("tip"),
                                    endpoint = it.getString("endpoint"),
                                )
                            },
                            optionsSource = field.optJSONObject("optionsSource")?.let {
                                SettingsOptionsSource(
                                    label = it.getString("label"),
                                    tip = it.optString("tip"),
                                    endpoint = it.getString("endpoint"),
                                    emptyMessage = it.optString("emptyMessage"),
                                    typeItMessage = it.optString("typeItMessage"),
                                )
                            },
                            requiresRestart = field.optBoolean("requiresRestart"),
                        ),
                    )
                }
            },
            extraAction = json.optJSONObject("extraAction")?.let {
                SettingsAction(
                    label = it.getString("label"),
                    tip = it.optString("tip"),
                    endpoint = it.getString("endpoint"),
                    method = it.optString("method", "POST"),
                )
            },
            group = json.optString("group"),
            // A server that predates grouping sends neither, and the defaults put every section in
            // one unnamed group at the end - the flat list this screen used to be.
            groupOrder = if (json.has("groupOrder")) json.optInt("groupOrder") else Int.MAX_VALUE,
            basic = json.optBoolean("basic"),
            restartService = json.optString("restartService").ifEmpty { "bridge" },
            // The server writes "dataEndpoint": null for every section but one, and optString turns
            // a JSON null into the string "null" - which sent every section to GET /null (404) and
            // drew all of them empty instead of reading the bulk snapshot.
            dataEndpoint = if (json.isNull("dataEndpoint")) null else json.optString("dataEndpoint").ifEmpty { null },
        )
    }

    // request() with the status handed back instead of mapped to an exception, for the routes
    // whose error body or status carries something the caller wants (the folder picker, the
    // download status probe).
    private fun requestWithStatus(
        path: String,
        method: String,
        body: String?,
        readTimeoutMillis: Int? = null,
    ): Pair<Int, String> {
        val url = URL(absoluteUrl(path) ?: throw IllegalArgumentException(
            "Enter a valid server address, such as http://192.168.1.50:3350.",
        ))
        val started = System.nanoTime()
        logger("$method $url", DiagnosticLevel.INFO)
        val connection = openConnection(url)
        try {
            readTimeoutMillis?.let { connection.readTimeout = it }
            connection.requestMethod = method
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.bufferedWriter(StandardCharsets.UTF_8).use { it.write(body) }
            }
            val status = connection.responseCode
            storeCookies(connection)
            logger("$method $status in ${elapsedMilliseconds(started)} ms", DiagnosticLevel.INFO)
            val text = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
            return status to text
        } catch (error: Exception) {
            logger(
                "$method failed after ${elapsedMilliseconds(started)} ms: " + (error.message ?: error.javaClass.simpleName),
                DiagnosticLevel.ERROR,
            )
            throw IOException(error.message ?: "Could not connect to ReelHouse.", error)
        } finally {
            connection.disconnect()
        }
    }

    // The raw way to the server for the audio and import APIs (audio/AudioApi, MediaImportApi):
    // the same address and session cookie as every other request here. Hands back any status
    // rather than throwing on non-2xx, because those callers give 401 and 404 their own
    // meanings; only a failure to reach the server at all throws. Not logged per request - the
    // player reports progress all day, and each tick would bury the Diagnostics screen.
    suspend fun rawRequest(
        method: String,
        path: String,
        query: Map<String, String>,
        body: ByteArray?,
        contentType: String?,
        timeoutMillis: Int?,
    ): Pair<Int, ByteArray> = withContext(Dispatchers.IO) {
        val queryString = query.entries.joinToString("&") {
            "${java.net.URLEncoder.encode(it.key, "UTF-8")}=${java.net.URLEncoder.encode(it.value, "UTF-8")}"
        }
        val url = URL((absoluteUrl(path) ?: throw IOException("No server address.")) + if (queryString.isEmpty()) "" else "?$queryString")
        val connection = openConnection(url)
        try {
            timeoutMillis?.let { connection.readTimeout = it }
            connection.requestMethod = method
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) {
                connection.doOutput = true
                contentType?.let { connection.setRequestProperty("Content-Type", it) }
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            storeCookies(connection)
            val bytes = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.use { it.readBytes() } ?: ByteArray(0)
            status to bytes
        } catch (error: IOException) {
            logger("$method $path failed: ${error.message ?: error.javaClass.simpleName}", DiagnosticLevel.NOTICE)
            throw error
        } finally {
            connection.disconnect()
        }
    }

    private fun request(
        path: String,
        method: String = "GET",
        body: String? = null,
        contentType: String = "application/json",
    ): String {
        val connection = openValidated(path, method, body, contentType)
        return try {
            connection.inputStream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
        } finally {
            connection.disconnect()
        }
    }

    // contentType is all but always JSON.
    private fun openValidated(
        path: String,
        method: String = "GET",
        body: String? = null,
        contentType: String = "application/json",
    ): HttpURLConnection {
        val url = URL(absoluteUrl(path) ?: throw IllegalArgumentException(
            "Enter a valid server address, such as http://192.168.1.50:3350.",
        ))
        val started = System.nanoTime()
        logger("$method $url", DiagnosticLevel.INFO)
        val connection = openConnection(url)

        try {
            connection.requestMethod = method
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", contentType)
                connection.outputStream.bufferedWriter(StandardCharsets.UTF_8).use { it.write(body) }
            }

            val status = connection.responseCode
            storeCookies(connection)
            logger("$method $status in ${elapsedMilliseconds(started)} ms", DiagnosticLevel.INFO)
            if (status !in 200..299) {
                val errorBody = connection.errorStream
                    ?.bufferedReader(StandardCharsets.UTF_8)
                    ?.use { it.readText() }
                    .orEmpty()
                val message = parseServerError(errorBody)
                    ?: if (status == 401) "This server requires you to sign in."
                    else "Server request failed (HTTP $status)."
                connection.disconnect()
                throw ReelHouseApiException(status, message)
            }
            return connection
        } catch (error: ReelHouseApiException) {
            throw error
        } catch (error: Exception) {
            connection.disconnect()
            logger(
                "$method failed after ${elapsedMilliseconds(started)} ms: " +
                    (error.message ?: error.javaClass.simpleName),
                DiagnosticLevel.ERROR,
            )
            throw IOException(error.message ?: "Could not connect to ReelHouse.", error)
        }
    }

    private fun openConnection(url: URL): HttpURLConnection {
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.instanceFollowRedirects = true
        cookieHeader(url)?.let { connection.setRequestProperty("Cookie", it) }
        return connection
    }

    // The session for `url`, from the in-memory jar or - after an app restart emptied it - from the
    // encrypted store. Shared with mediaHeaders() so ExoPlayer authenticates exactly like every
    // other request does; they used to resolve cookies differently and only one of them worked.
    private fun cookieHeader(url: URL): String? {
        cookieManager.get(url.toURI(), emptyMap())["Cookie"]
            ?.joinToString("; ")
            ?.takeIf(String::isNotBlank)
            ?.let { return it }

        val stored = sessionCookieStore.load(url)?.takeIf(String::isNotBlank) ?: return null
        // Rehydrate CookieManager too. Otherwise the first successful response after an app
        // restart (which normally has no Set-Cookie header) would look like an empty jar and
        // incorrectly erase the persisted session in storeCookies().
        //
        // Each cookie goes back as its own Set-Cookie pinned to Path=/. Both details matter: a
        // bare "a=1; b=2" parses as one cookie with a junk attribute, and a Set-Cookie carrying no
        // Path at all inherits the *requesting* URL's directory - so restoring during a call to
        // /api/media/items used to scope the session to /api/media/, leaving it invisible to
        // any lookup from the site root. That is what stopped ExoPlayer from sending it.
        val restored = restoredSetCookieValues(stored)
        if (restored.isNotEmpty()) {
            runCatching { cookieManager.put(url.toURI(), mapOf("Set-Cookie" to restored)) }
        }
        return stored
    }

    private fun storeCookies(connection: HttpURLConnection) {
        runCatching {
            cookieManager.put(connection.url.toURI(), connection.headerFields)
            val cookies = cookieManager.get(connection.url.toURI(), emptyMap())["Cookie"]?.joinToString("; ")
            if (cookies.isNullOrBlank()) {
                // An empty jar right after a response that *did* set a cookie is the tell: the
                // cookie was accepted and will never be handed back. Recorded rather than thrown
                // from here, since only login() knows the difference between "no session yet"
                // (every anonymous request) and "the session we just earned is unusable".
                droppedSecureCookie = carriesUnusableSecureCookie(
                    connection.url.protocol,
                    setCookieValues(connection),
                )
                sessionCookieStore.clear(connection.url)
            } else {
                droppedSecureCookie = false
                sessionCookieStore.save(connection.url, cookies)
            }
        }
    }

    private fun setCookieValues(connection: HttpURLConnection): List<String> =
        connection.headerFields
            .filterKeys { it != null && it.equals("Set-Cookie", ignoreCase = true) }
            .values
            .flatten()

    private fun normalizedBaseUrl(): String? = ServerAddress.normalize(baseUrl)

    private fun parseServerError(body: String): String? {
        if (body.isBlank()) return null
        return runCatching {
            val json = JSONObject(body)
            json.nullableString("error")
                ?: json.optJSONArray("errors")
                    ?.let { array ->
                        buildList {
                            for (index in 0 until array.length()) add(array.optString(index))
                        }.filter(String::isNotBlank).joinToString("\n").ifBlank { null }
                    }
        }.getOrNull()
    }

    private fun parseInstant(value: String): Instant = ServerTimestamp.parse(value)

    // optDouble returns NaN for a missing key rather than throwing, which is how a null
    // confidence/area on a motion row is told apart from a real 0.
    private fun JSONObject.nullableDouble(name: String): Double? =
        optDouble(name).takeUnless { it.isNaN() }

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        return buildList {
            for (index in 0 until length()) add(optString(index))
        }
    }

    private fun parseAccount(json: JSONObject): Account =
        Account(
            id = json.getString("id"),
            username = json.optString("username"),
            displayName = json.nullableString("displayName"),
            role = json.optString("role", "Viewer"),
            createdAt = parseInstant(json.getString("createdAt")),
        )

    private fun elapsedMilliseconds(started: Long): Long =
        (System.nanoTime() - started) / 1_000_000

    private fun JSONObject.nullableString(key: String): String? =
        if (isNull(key)) null else optString(key).takeIf { it.isNotBlank() }

    companion object {
        // With no scheme typed, a home-network address (an IP, a .local name, a bare computer
        // name) gets http://, which is how the dashboard ships; anything else is an internet
        // address and gets https:// - typing "home.example.com" must never send a password across
        // the internet in plain text. The remote address passes "https" to always get https://.
        fun normalizeAddress(value: String, defaultScheme: String? = null): String {
            val trimmed = value.trim()
            if (trimmed.isBlank()) return ""
            val home = defaultScheme == null && isHomeNetworkAddress(trimmed)
            val scheme = defaultScheme ?: if (home) "http" else "https"
            val withScheme = when {
                "://" in trimmed -> trimmed
                // Typed with no port, a home address gets the dashboard's :3350 too - a bare
                // "192.168.1.50" is what a new owner types, and it landed on port 80 and Offline.
                home -> withDashboardPort("$scheme://$trimmed")
                else -> "$scheme://$trimmed"
            }
            return withScheme.trimEnd('/')
        }

        const val DASHBOARD_PORT = 3350

        private fun withDashboardPort(address: String): String {
            val uri = runCatching { java.net.URI(address) }.getOrNull() ?: return address
            if (uri.host.isNullOrEmpty() || uri.port != -1) return address
            return runCatching {
                java.net.URI(uri.scheme, uri.userInfo, uri.host, DASHBOARD_PORT, uri.rawPath, uri.rawQuery, uri.rawFragment).toString()
            }.getOrDefault(address)
        }

        fun isHomeNetworkAddress(typed: String): Boolean {
            val host = runCatching { java.net.URI("x://$typed").host }.getOrNull()?.lowercase()?.trim('[', ']')
            if (host.isNullOrEmpty()) return true
            if (host == "localhost" || '.' !in host || ':' in host) return true
            if (host.split('.').all { it.toIntOrNull() != null }) return true
            return listOf(".local", ".lan", ".home", ".internal", ".home.arpa").any { host.endsWith(it) }
        }

        fun queryValue(value: String): String =
            URLEncoder.encode(value, StandardCharsets.UTF_8.name())
    }
}

// Splits a stored "Cookie:" request header back into one Set-Cookie value per cookie, each pinned
// to the site root, so the jar can be refilled from the encrypted store after a restart.
//
// Both halves are load-bearing. A whole header handed over as a single Set-Cookie parses as the
// first cookie plus junk attributes, silently dropping the rest. And a Set-Cookie with no Path
// takes the requesting URL's directory, so a session restored while fetching /api/media/items
// gets scoped to /api/media/ - matching later /api calls by luck while staying invisible to any
// lookup from the root, which is how media playback lost the session that the rest of the app had.
internal fun restoredSetCookieValues(storedHeader: String): List<String> =
    storedHeader.split(';')
        .map(String::trim)
        .filter(String::isNotEmpty)
        .map { "$it; Path=/" }

// Whether these Set-Cookie values include a session cookie that this connection's scheme can never
// send back: a Secure cookie delivered over plain http.
//
// java.net.CookieManager accepts such a cookie and then declines to return it on any http:// URL,
// with no error raised anywhere - so a successful login is followed by an unbroken run of 401s.
// The server marks its session cookie Secure whenever the request it answers arrived over https,
// which includes arriving through a TLS-terminating proxy (a Cloudflare Tunnel, say) that this app
// itself reaches over http. That combination is invisible from this side except right here.
//
// Deletion cookies are ignored on purpose: /api/auth/logout clears the session by setting an empty
// value with a past expiry, and that carries the same Secure attribute without being a session
// anyone is about to lose.
internal fun carriesUnusableSecureCookie(scheme: String, setCookieValues: List<String>): Boolean {
    if (!scheme.equals("http", ignoreCase = true)) return false
    return setCookieValues.any { header ->
        runCatching { HttpCookie.parse(header) }.getOrNull()
            .orEmpty()
            .any { it.secure && it.value.isNotBlank() }
    }
}
