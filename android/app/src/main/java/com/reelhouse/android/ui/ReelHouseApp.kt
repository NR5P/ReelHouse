package com.reelhouse.android.ui

import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.reelhouse.android.data.ConnectionState
import com.reelhouse.android.data.ServerCompatibility
import com.reelhouse.android.push.PushDestination
import com.reelhouse.android.push.PushNavigation
import com.reelhouse.android.ui.audio.*
import com.reelhouse.android.ui.components.ConnectionBadge
import com.reelhouse.android.ui.music.*
import com.reelhouse.android.ui.podcasts.*
import com.reelhouse.android.ui.screens.AccountAdminScreen
import com.reelhouse.android.ui.screens.AccountEditScreen
import com.reelhouse.android.ui.screens.AcknowledgementsScreen
import com.reelhouse.android.ui.screens.DashboardLoginScreen
import com.reelhouse.android.ui.screens.LoginScreen
import com.reelhouse.android.ui.screens.MEDIA_IMPORT_LIST_ROUTE
import com.reelhouse.android.ui.screens.MEDIA_IMPORT_ROUTE
import com.reelhouse.android.ui.screens.MOVIE_ADD_ROUTE
import com.reelhouse.android.ui.screens.MOVIE_DETAIL_ROUTE
import com.reelhouse.android.ui.screens.MOVIE_DOWNLOADS_ROUTE
import com.reelhouse.android.ui.screens.MOVIE_DOWNLOAD_SITES_ROUTE
import com.reelhouse.android.ui.screens.MOVIE_PLAYER_ROUTE
import com.reelhouse.android.ui.screens.MediaImportDetailScreen
import com.reelhouse.android.ui.screens.MediaImportScreen
import com.reelhouse.android.ui.screens.MediaLibrariesScreen
import com.reelhouse.android.ui.screens.MediaLibraryEditScreen
import com.reelhouse.android.ui.screens.MovieAddScreen
import com.reelhouse.android.ui.screens.MovieDetailScreen
import com.reelhouse.android.ui.screens.MovieDownloadSitesScreen
import com.reelhouse.android.ui.screens.MovieDownloadsScreen
import com.reelhouse.android.ui.screens.MoviePlayerScreen
import com.reelhouse.android.ui.screens.MoviesScreen
import com.reelhouse.android.ui.screens.ServerSettingsScreen
import com.reelhouse.android.ui.screens.ServerSetupScreen
import com.reelhouse.android.ui.screens.SettingsScreen
import com.reelhouse.android.ui.screens.mediaImportListRoute
import com.reelhouse.android.ui.screens.mediaImportRoute
import com.reelhouse.android.ui.screens.movieAddArguments
import com.reelhouse.android.ui.screens.movieAddRoute
import com.reelhouse.android.ui.screens.movieAddStart
import com.reelhouse.android.ui.screens.movieDetailRoute
import com.reelhouse.android.ui.screens.moviePlayerRoute
import com.reelhouse.android.ui.theme.ReelHouseAmber
import com.reelhouse.android.ui.theme.ReelHouseBackground
import com.reelhouse.android.ui.theme.ReelHouseGold
import com.reelhouse.android.ui.theme.ReelHouseWordmark
import com.reelhouse.android.ui.theme.ReelHousePanel
import com.reelhouse.android.ui.theme.ReelHouseTextDim
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

@Composable
fun ReelHouseApp(model: ReelHouseViewModel) {
    val state by model.state.collectAsStateWithLifecycle()

    LaunchedEffect(state.serverUrl) {
        if (state.isConfigured) model.connect(resetNetworkSession = true)
    }
    LaunchedEffect(state.serverUrl, state.requiresLogin) {
        while (state.isConfigured && !state.requiresLogin) {
            delay(30_000)
            model.connect()
        }
    }
    // Local-network discovery is only useful on the setup screen - stopped as soon as a server
    // is configured so a background NSD listener doesn't keep running (and draining battery)
    // for the rest of the app's lifetime.
    LaunchedEffect(state.isConfigured) {
        if (state.isConfigured) model.stopDiscovery() else model.startDiscovery()
    }

    var shellShown by rememberSaveable(state.serverUrl) { mutableStateOf(false) }

    Column(
        modifier = Modifier.fillMaxSize().background(ReelHouseBackground),
    ) {
        // Above the login screen as well as the main UI: "this server is too old" explains a
        // login that behaves oddly just as much as it explains an empty screen afterwards. It
        // renders nothing at all unless there's something to say.
        if (state.isConfigured) ServerVersionBanner(state.serverCompatibility)

        Box(modifier = Modifier.weight(1f)) {
            when {
                !state.isConfigured -> ServerSetupScreen(
                    initialAddress = state.serverUrl,
                    discoveredServers = state.discoveredServers,
                    onConnect = model::saveServer,
                )
                state.requiresLogin -> LoginScreen(
                    state = state,
                    onLogin = model::signIn,
                )
                // The very first connection to a server: which tabs exist isn't known yet, and
                // the shell opens on the first of them, so wait for the server's answer rather
                // than opening on Settings and jumping. Every later launch starts from what the
                // server said last time and never passes through here. Once the shell has been
                // shown it stays: a reconnect attempt must not tear down a screen in use.
                !shellShown && state.awaitingFirstAnswer -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                else -> {
                    LaunchedEffect(Unit) { shellShown = true }
                    AppShell(state = state, model = model)
                }
            }
        }
    }
}

private val ReelHouseUiState.awaitingFirstAnswer: Boolean
    get() = connectionState == ConnectionState.CHECKING && lastUpdated == null &&
        !moviesEnabled && !musicEnabled && !podcastsEnabled

// Advisory, never blocking - the app works normally behind it. Amber rather than red for that
// reason: this is "you'll want to update the server soon", not "something is broken". Collapses to
// nothing whenever the server is current, or when its version simply couldn't be read.
@Composable
private fun ServerVersionBanner(compatibility: ServerCompatibility) {
    val advisory = compatibility.advisory ?: return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(ReelHouseAmber.copy(alpha = 0.12f))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Filled.Warning,
            contentDescription = null,
            tint = ReelHouseAmber,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = advisory,
            style = MaterialTheme.typography.bodySmall,
            color = ReelHouseTextDim,
        )
    }
}

@Composable
private fun AppShell(
    state: ReelHouseUiState,
    model: ReelHouseViewModel,
) {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route
    val visibleSections = AppSection.visible(
        moviesEnabled = state.moviesEnabled,
        musicEnabled = state.musicEnabled,
        podcastsEnabled = state.podcastsEnabled,
    )
    // Where the app opens: the first section the server has switched on (Settings when none is).
    // Decided once per run - a section switched on or off later changes the bar, not the screen
    // the person is looking at.
    val startRoute = rememberSaveable { visibleSections.first().route }
    // Detail routes are nested under their section ("movies/{id}"), so a route match has to check
    // for that prefix too - otherwise the tab bar would deselect itself the moment a detail
    // screen opens.
    val selectedSection = AppSection.entries.firstOrNull { section ->
        currentRoute == section.route || currentRoute?.startsWith("${section.route}/") == true
    } ?: when {
        // The screens Music and Podcasts share (stats, alarms, downloads…) stay under the tab
        // they're usually opened from.
        currentRoute?.startsWith("audio/") == true && state.musicEnabled -> AppSection.MUSIC
        currentRoute?.startsWith("audio/") == true && state.podcastsEnabled -> AppSection.PODCASTS
        // "Import a list" belongs to whichever tab's downloads it fills.
        currentRoute?.startsWith("media-import/") == true ->
            if (backStackEntry?.arguments?.getString("kind") == "music") AppSection.MUSIC else AppSection.MOVIES
        else -> AppSection.entries.firstOrNull { it.route == startRoute } ?: AppSection.SETTINGS
    }
    // The movie player takes the whole screen: no bar, no rail. So does Wrapped.
    val chromeHidden = currentRoute == MOVIE_PLAYER_ROUTE || currentRoute == AudioRoutes.WRAPPED

    val onSelectSection: (AppSection) -> Unit = { section ->
        // Every tab switch becomes a real back-stack entry (no popUpTo/saveState) so system back
        // actually walks backward through tab history instead of exiting immediately - guarded
        // here so re-tapping the already-selected tab doesn't push a duplicate entry.
        if (currentRoute != section.route) {
            navController.navigate(section.route) { launchSingleTop = true }
        }
    }

    val context = LocalContext.current
    val tabBarPreferences = remember { TabBarPreferences(context.applicationContext) }
    val openTabBarEditor = { navController.navigate(TAB_BAR_EDITOR_ROUTE) { launchSingleTop = true } }

    // Music & Podcasts: the shared state behind both tabs' screens, the mini player and Now
    // Playing. See ui/audio/AudioUi.
    val audioScope = rememberCoroutineScope()
    val audioUi = remember(navController, state.isAdmin) {
        fun go(route: String) = navController.navigate(route) { launchSingleTop = true }
        AudioUi(
            runtime = model.audio,
            scope = audioScope,
            isAdmin = state.isAdmin,
            nav = AudioNav(
                openAlbum = { go("music/album/${Uri.encode(it)}") },
                openArtist = { go("music/artist/${Uri.encode(it)}") },
                openPlaylist = { go("music/playlist/${Uri.encode(it)}") },
                openGenre = { go("music/genre/${Uri.encode(it)}") },
                openDecade = { go("music/decade/$it") },
                openShow = { go("podcasts/show/${Uri.encode(it)}") },
                openEpisode = { go("podcasts/episode/${Uri.encode(it)}") },
                openPreview = { feed, itunes ->
                    go("podcasts/preview?feed=${Uri.encode(feed ?: "")}&itunes=${itunes ?: ""}")
                },
                open = { go(it) },
                back = { navController.popBackStack() },
            ),
        )
    }
    // Android 13+ shows the media notification and push notifications only with this permission.
    // Asked once, whichever comes first: the first time something plays, or once signed in to a
    // server that will actually send push to this phone (this shell only exists after sign-in).
    // Playback works either way, and Settings -> Notifications leads to the system switch after.
    // Only whether something is queued: collecting the whole player state here would recompose the
    // entire shell on every play/pause.
    val audioHasQueue by remember(model) { model.audio.engine.state.map { it.hasQueue }.distinctUntilChanged() }.collectAsStateWithLifecycle(false)
    val notificationAsk = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        model.refreshNotificationPermission()
    }
    LaunchedEffect(audioHasQueue, state.pushDeliverable) {
        if ((audioHasQueue || state.pushDeliverable) && android.os.Build.VERSION.SDK_INT >= 33) {
            val prefs = context.getSharedPreferences("reelhouse_audio", android.content.Context.MODE_PRIVATE)
            val granted = androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!granted && !prefs.getBoolean("askedNotifications", false)) {
                prefs.edit().putBoolean("askedNotifications", true).apply()
                notificationAsk.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    CompositionLocalProvider(LocalAudioUi provides audioUi) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val useRail = maxWidth >= 840.dp
        if (useRail) {
            Row(Modifier.fillMaxSize()) {
                if (!chromeHidden) {
                    ReelHouseNavigationRail(
                        selected = selectedSection,
                        sections = visibleSections,
                        state = state,
                        onSelected = onSelectSection,
                    )
                }
                Column(Modifier.weight(1f)) {
                    ReelHouseNavHost(
                        navController = navController,
                        startRoute = startRoute,
                        state = state,
                        model = model,
                        tabBarPreferences = tabBarPreferences,
                        // The rail shows every section, so there is no bar to customize.
                        onCustomizeTabBar = null,
                        modifier = Modifier.weight(1f),
                    )
                    if (!chromeHidden) MiniPlayer(Modifier.navigationBarsPadding())
                }
            }
        } else {
            val layout = tabBarPreferences.layout(visibleSections)
            var showMore by rememberSaveable { mutableStateOf(false) }
            Scaffold(
                containerColor = ReelHouseBackground,
                bottomBar = {
                    if (!chromeHidden) Column {
                    // The mini player sits on the tab bar, on every tab.
                    MiniPlayer()
                    NavigationBar(containerColor = ReelHousePanel) {
                        layout.bar.forEach { item ->
                            NavigationBarItem(
                                selected = selectedSection == item,
                                onClick = { onSelectSection(item) },
                                icon = { Icon(item.icon, contentDescription = item.title) },
                                label = { Text(item.title) },
                            )
                        }
                        if (layout.showsMore) {
                            // Selected whenever the section on screen has no tab of its own.
                            NavigationBarItem(
                                selected = selectedSection !in layout.bar,
                                onClick = { showMore = true },
                                icon = { Icon(Icons.Default.MoreHoriz, contentDescription = "More") },
                                label = { Text("More") },
                            )
                        }
                    }
                    }
                },
            ) { padding ->
                ReelHouseNavHost(
                    navController = navController,
                    startRoute = startRoute,
                    state = state,
                    model = model,
                    tabBarPreferences = tabBarPreferences,
                    onCustomizeTabBar = openTabBarEditor,
                    modifier = Modifier.padding(padding),
                )
            }
            if (showMore && layout.showsMore) {
                MoreSectionsSheet(
                    sections = layout.more,
                    onSelect = { section ->
                        showMore = false
                        onSelectSection(section)
                    },
                    onEdit = {
                        showMore = false
                        openTabBarEditor()
                    },
                    onDismiss = { showMore = false },
                )
            }
        }
        // Now Playing, the long-press menus, the speaker picker and the snackbar, over everything.
        AudioOverlays(snackbarBottom = if (useRail) 80.dp else 150.dp)
    }
    }
}

// Under Settings, so the bar highlights Settings while it's open.
private const val TAB_BAR_EDITOR_ROUTE = "settings/tab-bar"
private const val MEDIA_LIBRARIES_ROUTE = "settings/media-libraries"

@Composable
private fun ReelHouseNavHost(
    navController: NavHostController,
    startRoute: String,
    state: ReelHouseUiState,
    model: ReelHouseViewModel,
    tabBarPreferences: TabBarPreferences,
    onCustomizeTabBar: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    NavHost(navController = navController, startDestination = startRoute, modifier = modifier) {
        composable(AppSection.MOVIES.route) {
            MoviesScreen(
                state = state,
                model = model,
                onItem = { navController.navigate(movieDetailRoute(it)) },
                onPlay = { id, start -> navController.navigate(moviePlayerRoute(id, start)) },
                onManageLibraries = { navController.navigate(MEDIA_LIBRARIES_ROUTE) { launchSingleTop = true } },
                onAddDownload = { navController.navigate(movieAddRoute()) { launchSingleTop = true } },
                onDownloads = { navController.navigate(MOVIE_DOWNLOADS_ROUTE) { launchSingleTop = true } },
                onAddDownloadAt = { navController.navigate(movieAddRoute(it)) { launchSingleTop = true } },
            )
        }
        // Movie downloads (core/docs/MOVIE_DOWNLOADS.md). A started download replaces the Add
        // screen with the queue, so Back from there returns to Movies. The search's download
        // offer opens Add at a title (see movieAddRoute); closing it returns to the search.
        composable(MOVIE_ADD_ROUTE, arguments = movieAddArguments) { entry ->
            MovieAddScreen(
                model = model,
                start = movieAddStart(entry.arguments),
                onBack = { navController.popBackStack() },
                onImportList = { navController.navigate(mediaImportRoute("movies")) { launchSingleTop = true } },
                onDownloadStarted = {
                    navController.navigate(MOVIE_DOWNLOADS_ROUTE) {
                        popUpTo(MOVIE_ADD_ROUTE) { inclusive = true }
                        launchSingleTop = true
                    }
                },
            )
        }
        composable(MOVIE_DOWNLOADS_ROUTE) {
            MovieDownloadsScreen(
                model = model,
                onBack = { navController.popBackStack() },
                onAdd = { navController.navigate(movieAddRoute()) { launchSingleTop = true } },
                onSites = { navController.navigate(MOVIE_DOWNLOAD_SITES_ROUTE) { launchSingleTop = true } },
                onOpenItem = { navController.navigate(movieDetailRoute(it)) },
                importApi = remember { model.mediaImportApi("movies") },
                onImportList = { navController.navigate(mediaImportRoute("movies")) { launchSingleTop = true } },
                onOpenImport = { navController.navigate(mediaImportListRoute("movies", it)) },
            )
        }
        composable(MOVIE_DOWNLOAD_SITES_ROUTE) {
            MovieDownloadSitesScreen(model = model, onBack = { navController.popBackStack() })
        }
        // "Import a list" on Movies and Music (core/docs/MOVIE_DOWNLOADS.md). A started list
        // replaces the import screen with that tab's Downloads, where the list's card shows.
        composable(
            MEDIA_IMPORT_ROUTE,
            arguments = listOf(navArgument("kind") { type = NavType.StringType }),
        ) { entry ->
            val kind = entry.arguments?.getString("kind") ?: "music"
            val api = remember(kind) { model.mediaImportApi(kind) }
            val context = LocalContext.current
            MediaImportScreen(
                api = api,
                onBack = { navController.popBackStack() },
                onStarted = { message ->
                    Toast.makeText(context, message, Toast.LENGTH_LONG).show()
                    navController.navigate(if (kind == "movies") MOVIE_DOWNLOADS_ROUTE else AudioRoutes.ALBUM_DOWNLOADS) {
                        popUpTo(MEDIA_IMPORT_ROUTE) { inclusive = true }
                        launchSingleTop = true
                    }
                },
            )
        }
        composable(
            MEDIA_IMPORT_LIST_ROUTE,
            arguments = listOf(
                navArgument("kind") { type = NavType.StringType },
                navArgument("id") { type = NavType.StringType },
            ),
        ) { entry ->
            val kind = entry.arguments?.getString("kind") ?: "music"
            val api = remember(kind) { model.mediaImportApi(kind) }
            MediaImportDetailScreen(
                api = api,
                id = entry.arguments?.getString("id").orEmpty(),
                onBack = { navController.popBackStack() },
            )
        }
        composable(
            route = MOVIE_DETAIL_ROUTE,
            arguments = listOf(navArgument("id") { type = NavType.StringType }),
        ) { entry ->
            MovieDetailScreen(
                state = state,
                model = model,
                itemId = entry.arguments?.getString("id").orEmpty(),
                onBack = { navController.popBackStack() },
                onItem = { navController.navigate(movieDetailRoute(it)) },
                onPlay = { id, start -> navController.navigate(moviePlayerRoute(id, start)) },
            )
        }
        composable(
            route = MOVIE_PLAYER_ROUTE,
            arguments = listOf(
                navArgument("id") { type = NavType.StringType },
                navArgument("start") { type = NavType.StringType; nullable = true; defaultValue = null },
            ),
        ) { entry ->
            MoviePlayerScreen(
                model = model,
                itemId = entry.arguments?.getString("id").orEmpty(),
                start = entry.arguments?.getString("start")?.toDoubleOrNull(),
                onBack = { navController.popBackStack() },
                // The next episode replaces this player rather than stacking on it, so Back
                // still lands on the screen the first episode was started from.
                onPlayNext = { nextId ->
                    navController.popBackStack()
                    navController.navigate(moviePlayerRoute(nextId, null))
                },
            )
        }

        // ---- Music & Podcasts (core/docs/MUSIC_AND_PODCASTS.md) ----
        composable(AppSection.MUSIC.route) { MusicScreen(state) }
        composable(AudioRoutes.ALBUM) { AlbumScreen(it.arguments?.getString("id").orEmpty()) }
        composable(AudioRoutes.ARTIST) { ArtistScreen(it.arguments?.getString("id").orEmpty()) }
        composable(AudioRoutes.PLAYLIST) { PlaylistScreen(it.arguments?.getString("id").orEmpty()) }
        composable(AudioRoutes.GENRE) { GenreScreen(it.arguments?.getString("name").orEmpty()) }
        composable(AudioRoutes.DECADE) { DecadeScreen(it.arguments?.getString("decade")?.toIntOrNull() ?: 1990) }
        composable(AudioRoutes.SMART) { SmartPlaylistEditor(it.arguments?.getString("id")?.takeIf { id -> id != "new" }) }
        composable(AudioRoutes.FOLDERS) { FoldersScreen() }
        composable("music/albums?sort={sort}", arguments = listOf(navArgument("sort") { type = NavType.StringType; defaultValue = "title" })) {
            AllAlbumsScreen(it.arguments?.getString("sort") ?: "title")
        }
        composable(AudioRoutes.ADD) { MusicAddScreen() }
        composable(AudioRoutes.ALBUM_DOWNLOADS) { AlbumDownloadsScreen() }
        composable(AudioRoutes.SUGGESTIONS) { com.reelhouse.android.ui.music.MusicSuggestionsScreen() }
        composable(AudioRoutes.MUSIC_LIBRARIES) { MusicLibrariesScreen(state, model, onBack = { navController.popBackStack() }) }
        composable(AppSection.PODCASTS.route) { PodcastsScreen(state) }
        composable(AudioRoutes.SHOW) { ShowScreen(it.arguments?.getString("id").orEmpty()) }
        composable(AudioRoutes.EPISODE) { EpisodeScreen(it.arguments?.getString("id").orEmpty()) }
        composable(
            AudioRoutes.PREVIEW,
            arguments = listOf(
                navArgument("feed") { type = NavType.StringType; defaultValue = "" },
                navArgument("itunes") { type = NavType.StringType; defaultValue = "" },
            ),
        ) { entry ->
            PodcastPreviewScreen(
                entry.arguments?.getString("feed")?.takeIf { it.isNotBlank() },
                entry.arguments?.getString("itunes")?.toLongOrNull(),
            )
        }
        composable(AudioRoutes.BOOKMARKS) { BookmarksScreen() }
        composable(AudioRoutes.TRANSCRIPT_SEARCH) { TranscriptSearchScreen() }
        composable(AudioRoutes.CLIPS) { ClipsScreen() }
        composable("podcasts/clip/{id}") { ClipMakerScreen(it.arguments?.getString("id").orEmpty()) }
        composable(AudioRoutes.UP_NEXT) { UpNextPane() }
        composable(AudioRoutes.DOWNLOADS) { DownloadsScreen() }
        composable(AudioRoutes.ALARMS) { AlarmsScreen() }
        composable(AudioRoutes.ALARM) { AlarmEditorScreen(it.arguments?.getString("id")?.takeIf { id -> id != "new" }) }
        composable(AudioRoutes.BRIEFING) { BriefingScreen() }
        composable(AudioRoutes.STATS) { StatsScreen() }
        composable(AudioRoutes.WRAPPED) { WrappedScreen() }
        composable(AudioRoutes.EQUALIZER) { EqualizerScreen() }
        composable(AudioRoutes.SETTINGS) { AudioSettingsScreen() }
        composable(AudioRoutes.LISTENBRAINZ) { ListenBrainzScreen() }

        composable(AppSection.SETTINGS.route) {
            SettingsScreen(
                state = state,
                model = model,
                onManageAccounts = { navController.navigate("settings/accounts") },
                onDashboardLogin = { navController.navigate("settings/login") },
                onAcknowledgements = { navController.navigate("settings/acknowledgements") },
                onServerSettings = { navController.navigate("settings/server") },
                onMediaLibraries = { navController.navigate(MEDIA_LIBRARIES_ROUTE) },
                onMusicAndPodcasts = if (state.musicEnabled || state.podcastsEnabled) {
                    { navController.navigate(AudioRoutes.SETTINGS) }
                } else null,
                onCustomizeTabBar = onCustomizeTabBar,
            )
        }
        composable(TAB_BAR_EDITOR_ROUTE) {
            TabBarEditorScreen(
                preferences = tabBarPreferences,
                visible = AppSection.visible(
                    moviesEnabled = state.moviesEnabled,
                    musicEnabled = state.musicEnabled,
                    podcastsEnabled = state.podcastsEnabled,
                ),
                onBack = { navController.popBackStack() },
            )
        }

        composable("settings/server") {
            ServerSettingsScreen(
                state = state,
                model = model,
                onBack = { navController.popBackStack() },
            )
        }

        composable("settings/acknowledgements") {
            AcknowledgementsScreen(state = state, onBack = { navController.popBackStack() })
        }

        composable(MEDIA_LIBRARIES_ROUTE) {
            MediaLibrariesScreen(
                state = state,
                model = model,
                onBack = { navController.popBackStack() },
                onEditLibrary = { id -> navController.navigate("$MEDIA_LIBRARIES_ROUTE/${Uri.encode(id ?: "new")}") },
            )
        }
        composable(
            "$MEDIA_LIBRARIES_ROUTE/{id}",
            arguments = listOf(navArgument("id") { type = NavType.StringType }),
        ) { entry ->
            MediaLibraryEditScreen(
                state = state,
                model = model,
                libraryId = entry.arguments?.getString("id")?.takeIf { it != "new" },
                onBack = { navController.popBackStack() },
            )
        }

        composable("settings/login") {
            DashboardLoginScreen(
                state = state,
                model = model,
                onBack = { navController.popBackStack() },
            )
        }

        composable("settings/accounts") {
            AccountAdminScreen(
                state = state,
                model = model,
                onBack = { navController.popBackStack() },
                onAddAccount = { navController.navigate("settings/accounts/new") },
            )
        }
        composable("settings/accounts/new") {
            AccountEditScreen(
                model = model,
                onBack = { navController.popBackStack() },
            )
        }
    }

    // A tapped push notification (see push/PushNotifications). Here, after NavHost, so the graph
    // is set before navigating; and only ever composed once signed in, so a notification tapped
    // at the login screen waits for it. A section the server has switched off opens nothing.
    val pushOpen by PushNavigation.pending.collectAsStateWithLifecycle()
    LaunchedEffect(pushOpen) {
        val open = pushOpen ?: return@LaunchedEffect
        PushNavigation.pending.value = null
        fun go(route: String) = runCatching { navController.navigate(route) { launchSingleTop = true } }
        when (val destination = open.destination()) {
            // The show first, so Back from the episode lands on it rather than leaving the app.
            is PushDestination.Episode -> if (state.podcastsEnabled) {
                destination.showId?.let { go("podcasts/show/${Uri.encode(it)}") }
                go("podcasts/episode/${Uri.encode(destination.episodeId)}")
            }
            is PushDestination.Show -> if (state.podcastsEnabled) go("podcasts/show/${Uri.encode(destination.showId)}")
            is PushDestination.MovieItem -> if (state.moviesEnabled) go(movieDetailRoute(destination.itemId))
            PushDestination.Movies -> if (state.moviesEnabled) go(AppSection.MOVIES.route)
            PushDestination.None -> Unit
        }
    }
}

@Composable
private fun ReelHouseNavigationRail(
    selected: AppSection,
    sections: List<AppSection>,
    state: ReelHouseUiState,
    onSelected: (AppSection) -> Unit,
) {
    NavigationRail(
        containerColor = ReelHousePanel,
        header = {
            Column(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                ReelHouseWordmark(style = MaterialTheme.typography.labelLarge)
            }
        },
    ) {
        sections.forEach { item ->
            NavigationRailItem(
                selected = selected == item,
                onClick = { onSelected(item) },
                icon = { Icon(item.icon, contentDescription = item.title) },
                label = { Text(item.title) },
            )
        }
        Box(Modifier.weight(1f))
        ConnectionBadge(
            state.connectionState,
            Modifier.padding(horizontal = 10.dp, vertical = 18.dp),
        )
    }
}
