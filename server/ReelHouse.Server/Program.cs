using System.Security.Cryptography;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Configuration.Json;
using Microsoft.Extensions.DependencyInjection.Extensions;
using ReelHouse;

var builder = WebApplication.CreateBuilder(args);

// Everything this server keeps - libraries, accounts, artwork, settings - lives under one data
// folder, "data" beside the program unless DataDirectory says otherwise.
var dataDirectory = builder.Configuration["DataDirectory"] ?? "data";
var dataRoot = Path.GetFullPath(Path.IsPathRooted(dataDirectory)
    ? dataDirectory
    : Path.Combine(builder.Environment.ContentRootPath, dataDirectory));
Directory.CreateDirectory(dataRoot);

// The settings the web page and the apps edit (Settings tab) are written to data/settings.json,
// never to the shipped appsettings.json - so an update can replace the program's own files
// without losing anyone's choices. It is layered just above appsettings.json, so environment
// variables and the command line still win.
// SettingsPath moves it elsewhere (the tests point each host at a scratch file).
var settingsPath = Path.GetFullPath(builder.Configuration["SettingsPath"] is { Length: > 0 } configuredSettings
    ? configuredSettings
    : Path.Combine(dataRoot, "settings.json"));
if (!File.Exists(settingsPath)) File.WriteAllText(settingsPath, "{}\n");
{
    var sources = builder.Configuration.Sources;
    var lastJson = -1;
    for (var i = 0; i < sources.Count; i++)
        if (sources[i] is JsonConfigurationSource) lastJson = i;
    var settingsSource = new JsonConfigurationSource { Path = settingsPath, Optional = true, ReloadOnChange = true };
    settingsSource.ResolveFileProvider();
    sources.Insert(lastJson + 1, settingsSource);
}

// Lets ASPNETCORE_URLS outrank the settings file, which the framework's own source ordering
// otherwise reverses; see HostUrls.
if (HostUrls.ResolveOverride(args, Environment.GetEnvironmentVariable(HostUrls.EnvironmentVariable)) is { } urlsOverride)
    builder.Configuration[HostUrls.ConfigurationKey] = urlsOverride;

builder.Services.Configure<Microsoft.AspNetCore.Http.Json.JsonOptions>(options =>
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));

// The same binaries run as a Windows Service, a systemd unit, or straight from a terminal.
builder.Host.UseWindowsService();
builder.Host.UseSystemd();

// HTTPS alongside plain HTTP, on by default, with a certificate made on first start when none is
// configured - see AutoCertificateProvisioner. An explicit CertificatePath/KeyPath is left alone.
var httpsSettings = HttpsSettings.FromConfiguration(builder.Configuration);
if (httpsSettings.Enabled && string.IsNullOrWhiteSpace(httpsSettings.CertificatePath) && string.IsNullOrWhiteSpace(httpsSettings.KeyPath))
{
    var certDirectory = Path.Combine(dataRoot, "certs");
    try
    {
        var provisioned = AutoCertificateProvisioner.EnsureCertificate(certDirectory);
        httpsSettings = httpsSettings with { CertificatePath = provisioned.CertificatePath, KeyPath = provisioned.KeyPath };
        builder.Configuration["Https:CertificatePath"] = provisioned.CertificatePath;
        builder.Configuration["Https:KeyPath"] = provisioned.KeyPath;
        builder.Configuration[CertificateAuthorityEndpoints.ConfigurationKey] = provisioned.AuthorityCertificatePath;
        if (provisioned.Reissued)
        {
            Console.WriteLine($"Generated a local HTTPS certificate authority and server certificate in {certDirectory}.");
            Console.WriteLine($"To remove the browser warning, trust {provisioned.AuthorityCertificatePath} on each device (Settings -> HTTPS in the web page has a download link).");
        }
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException)
    {
        Console.WriteLine($"Could not auto-generate an HTTPS certificate ({ex.Message}). Continuing on plain HTTP.");
    }
}
if (string.IsNullOrWhiteSpace(builder.Configuration[CertificateAuthorityEndpoints.ConfigurationKey])
    && !string.IsNullOrWhiteSpace(httpsSettings.CertificatePath))
{
    var sibling = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(httpsSettings.CertificatePath)) ?? "", "ca.crt");
    if (File.Exists(sibling))
        builder.Configuration[CertificateAuthorityEndpoints.ConfigurationKey] = sibling;
}
var httpsEnabled = httpsSettings.CanEnable(out var httpsSkipReason);

// A third, dedicated port for traffic from outside the LAN (a Cloudflare Tunnel, say): always
// login, always HTTPS. See InternetExposedSettings.
var internetExposedSettings = InternetExposedSettings.FromConfiguration(builder.Configuration);
var internetExposedEnabled = internetExposedSettings.CanEnable(httpsSettings, out var internetExposedSkipReason);
var httpPort = HttpsSettings.ParseHttpPort(builder.Configuration["Urls"]);

if (httpsEnabled)
{
    // Calling Listen() at all makes Kestrel ignore Urls, so the HTTP port is re-declared here.
    var certificate = httpsSettings.LoadCertificate();
    builder.WebHost.ConfigureKestrel(kestrel =>
    {
        kestrel.ListenAnyIP(httpPort);
        kestrel.ListenAnyIP(httpsSettings.Port, listen => listen.UseHttps(certificate));
        if (internetExposedEnabled)
            kestrel.ListenAnyIP(internetExposedSettings.Port, listen => listen.UseHttps(certificate));
    });
}

var discoveryEndpoint = new DiscoveryEndpoint(httpsEnabled, httpsEnabled ? httpsSettings.Port : httpPort);
builder.Services.AddSingleton(internetExposedSettings with { Enabled = internetExposedEnabled });

var appSettingsFile = new AppSettingsFile(settingsPath);
builder.Services.AddSingleton(appSettingsFile);
// Internet Exposed Mode is read through the "web" key in the code it came from; here there is one
// process and one settings file, so both names are the same file.
builder.Services.AddKeyedSingleton("web", appSettingsFile);

// Found on the LAN as "_reelhouse._tcp" - see MdnsAdvertiserService.
builder.Services.AddSingleton(DiscoverySettings.FromConfiguration(builder.Configuration));
builder.Services.AddSingleton(discoveryEndpoint);
builder.Services.AddHostedService<MdnsAdvertiserService>();

builder.Services.TryAddSingleton(TimeProvider.System);
builder.Services.AddHttpClient();

// ---- Movies & TV (docs/MOVIES.md) ----
// Artwork fetched from TMDB and extracted subtitles are caches beside media.db; HLS sessions get
// their own folder, wiped at startup because no session survives a restart.
builder.Services.AddSingleton<IMediaStore>(new SqliteMediaStore(dataRoot));
builder.Services.AddSingleton(new MediaArtCache(Path.Combine(dataRoot, "media-art"), Path.Combine(dataRoot, "media-subs")));
builder.Services.AddHttpClient(TmdbClient.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(20);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse/1.0 (self-hosted home media server)");
});
builder.Services.AddSingleton<TmdbClient>();
// Folders shared from other computers are read over SMB by the server itself (MediaNetwork.cs);
// ffmpeg reaches those files through a loopback relay.
builder.Services.AddSingleton(new MediaNetworkComputerStore(dataRoot));
builder.Services.AddSingleton<MediaNetworkResolver>();
builder.Services.AddSingleton<MediaNetworkFileSystem>();
builder.Services.AddSingleton<MediaFileRelay>();
builder.Services.AddSingleton<MediaFiles>();
builder.Services.AddSingleton<MediaScanner>();
builder.Services.AddSingleton(sp => new MediaHlsManager(
    sp.GetRequiredService<IConfiguration>(), dataRoot, sp.GetRequiredService<ILogger<MediaHlsManager>>()));
builder.Services.AddHostedService<MediaScanWorker>();

// ---- "+ Add": torrent downloads (docs/MOVIE_DOWNLOADS.md) ----
// Prowlarr and qBittorrent inside a VPN-only network namespace, started and stopped on demand.
builder.Services.AddSingleton(new MediaDownloadStore(dataRoot));
builder.Services.AddHttpClient(QbittorrentClient.HttpClientName, client => client.Timeout = TimeSpan.FromSeconds(30));
// Redirects are followed by hand: a release's download link may redirect to a magnet link.
builder.Services.AddHttpClient(ProwlarrClient.HttpClientName, client => client.Timeout = TimeSpan.FromSeconds(120))
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false });
builder.Services.AddHttpClient(MediaDownloadManager.HomeIpClientName, client => client.Timeout = TimeSpan.FromSeconds(10));
builder.Services.AddHttpClient(MediaVpnConfig.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(20);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse/1.0");
});
builder.Services.AddSingleton(sp => new MediaVpnConfig(
    sp.GetRequiredService<IHttpClientFactory>(), dataRoot, sp.GetRequiredService<ILogger<MediaVpnConfig>>()));
builder.Services.AddSingleton<QbittorrentClient>();
builder.Services.AddSingleton<ProwlarrClient>();
builder.Services.AddSingleton<IMediaDownloadStack, SystemdMediaDownloadStack>();
// ---- Push notifications (docs/PUSH.md) ----
// Straight to Apple and Google with the keys in Settings -> PUSH NOTIFICATIONS; phones sign up
// through /api/push/devices.
builder.Services.AddHttpClient(PushSenderHelpers.HttpClientName, client => client.Timeout = TimeSpan.FromSeconds(15));
builder.Services.AddSingleton(new PushDeviceStore(dataRoot));
builder.Services.AddSingleton<ApnsSender>();
builder.Services.AddSingleton<FcmSender>();
// A purchased install has no keys: it goes through the ReelHouse push relay with its license.
builder.Services.AddSingleton(new LicenseStore(Path.Combine(dataRoot, LicenseStore.FileName)));
builder.Services.AddHttpClient(PushRelayClient.HttpClientName, client => client.Timeout = TimeSpan.FromSeconds(15));
builder.Services.AddSingleton<PushRelayClient>();
builder.Services.AddSingleton(sp => new PushNotifier(
    sp.GetRequiredService<AppSettingsFile>(), sp.GetRequiredService<PushDeviceStore>(), sp.GetRequiredService<IAccountStore>(),
    sp.GetRequiredService<ApnsSender>(), sp.GetRequiredService<FcmSender>(), sp.GetRequiredService<PushRelayClient>(),
    sp.GetRequiredService<LicenseStore>(), dataRoot, sp.GetRequiredService<ILogger<PushNotifier>>()));
builder.Services.AddSingleton<IPushNotifier>(sp => sp.GetRequiredService<PushNotifier>());
builder.Services.AddSingleton<OwnerNotifier>();
builder.Services.AddSingleton<IOwnerNotifier>(sp => sp.GetRequiredService<OwnerNotifier>());
builder.Services.AddSingleton(sp => new MullvadAccountWatch(
    sp.GetRequiredService<MediaVpnConfig>(), sp.GetRequiredService<IOwnerNotifier>(), dataRoot,
    sp.GetRequiredService<ILogger<MullvadAccountWatch>>(), sp.GetRequiredService<TimeProvider>()));
builder.Services.AddSingleton<MediaDownloadManager>();
builder.Services.AddHostedService<MediaDownloadWorker>();
builder.Services.AddSingleton<MediaImportService>();
builder.Services.AddHostedService<MediaImportWorker>();
builder.Services.AddHostedService<MullvadAccountWorker>();

// ---- Music (docs/MUSIC_AND_PODCASTS.md sections 2-4) ----
builder.Services.AddSingleton<IMusicStore>(new SqliteMusicStore(dataRoot));
builder.Services.AddSingleton(new MusicArtCache(Path.Combine(dataRoot, "music-art")));
// Sized (and always baseline-JPEG) copies of film/TV and podcast art for ?size= - see ArtSizing.cs.
builder.Services.AddSingleton(new SizedArtCache(Path.Combine(dataRoot, "sized-art")));
builder.Services.AddHttpClient(MusicCoverArtClient.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(20);
    // MusicBrainz turns away clients that don't say who they are.
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse-Music/1.0 (self-hosted home media server)");
});
builder.Services.AddHttpClient(MusicLyricsService.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(15);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse-Music/1.0 (self-hosted home media server)");
});
builder.Services.AddSingleton<MusicCoverArtClient>();
// The second online cover source, after the Cover Art Archive (MusicArt.cs).
builder.Services.AddHttpClient(MusicITunesArtClient.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(20);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse-Music/1.0 (self-hosted home media server)");
});
builder.Services.AddSingleton<MusicITunesArtClient>();
// Cover downloads follow redirects by hand, so every hop is checked against MusicArtHosts.
builder.Services.AddHttpClient(MusicArtDownloader.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(30);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse-Music/1.0 (self-hosted home media server)");
}).ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false });
builder.Services.AddSingleton<MusicArtDownloader>();
builder.Services.AddSingleton<MusicCoverService>();
builder.Services.AddSingleton<MusicLyricsService>();
builder.Services.AddSingleton<MusicCatalogCache>();
builder.Services.AddSingleton<MusicScanner>();
builder.Services.AddSingleton(sp => new MusicTranscoder(
    sp.GetRequiredService<MediaFiles>(), Path.Combine(dataRoot, "audio-cache"),
    sp.GetRequiredService<IConfiguration>()["FfmpegPath"] ?? "ffmpeg", sp.GetRequiredService<ILogger<MusicTranscoder>>()));
builder.Services.AddSingleton<MusicService>();
builder.Services.AddSingleton<IMusicAudioSource>(sp => sp.GetRequiredService<MusicService>());
builder.Services.AddHostedService<MusicScanWorker>();
// "+ Add" on the Music tab rides the same download stack as Movies (MusicDownloads.cs).
builder.Services.AddHttpClient(MusicDownloadLookup.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(15);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse/1.0 (self-hosted home media server)");
});
builder.Services.AddSingleton<MusicDownloadLookup>();
// "Suggested for you": similar artists from ListenBrainz (MusicSuggestions.cs).
builder.Services.AddHttpClient(ListenBrainzMusicSimilarity.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(20);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse/1.0 (self-hosted home media server)");
});
builder.Services.AddSingleton<IMusicSimilarity, ListenBrainzMusicSimilarity>();
builder.Services.AddSingleton<MusicSuggestionService>();

// ---- What Music and Podcasts share (Audio*.cs): resume, speakers, wake-up alarms, the morning
// briefing, listening stats, ListenBrainz ----
builder.Services.AddSingleton(new SqliteAudioStore(dataRoot));
builder.Services.AddSingleton(sp => new AudioSpeakerHub(sp.GetRequiredService<TimeProvider>()));
builder.Services.AddSingleton<IAudioNotifier, AudioNotifier>();
builder.Services.AddSingleton<AudioBriefingBuilder>();
builder.Services.AddSingleton<AudioDirector>();
builder.Services.AddSingleton<AudioAlarmWorker>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<AudioAlarmWorker>());
builder.Services.AddHttpClient(AudioListenBrainz.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(15);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse/1.0 (self-hosted home media server)");
});
builder.Services.AddSingleton<AudioListenBrainz>();
builder.Services.AddSingleton<IListenBrainzSubmitter>(sp => sp.GetRequiredService<AudioListenBrainz>());
builder.Services.AddHostedService(sp => sp.GetRequiredService<AudioListenBrainz>());

// ---- Podcasts (docs/MUSIC_AND_PODCASTS.md sections 5-6) ----
// Feeds are fetched with redirects followed by hand (so a permanent move updates the stored
// address); episode files and the audio relay follow redirects and take as long as they take.
// Both fetch URLs a feed supplied, so neither may reach the LAN - see PublicNetworkGuard.
builder.Services.AddSingleton<IPodcastStore>(new SqlitePodcastStore(dataRoot));
builder.Services.AddSingleton(sp => new PodcastLocations(dataRoot, sp.GetRequiredService<AppSettingsFile>()));
builder.Services.AddHttpClient(PodcastHttp.HttpClientName, client =>
{
    client.Timeout = TimeSpan.FromSeconds(30);
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse/1.0 (Podcasts)");
}).ConfigurePrimaryHttpMessageHandler(sp => PublicNetworkGuard.Apply(new SocketsHttpHandler
{
    AllowAutoRedirect = false,
    AutomaticDecompression = System.Net.DecompressionMethods.All
}, sp.GetRequiredService<IConfiguration>()));
builder.Services.AddHttpClient(PodcastDownloadManager.HttpClientName, client =>
{
    client.Timeout = Timeout.InfiniteTimeSpan;
    client.DefaultRequestHeaders.UserAgent.ParseAdd("ReelHouse/1.0 (Podcasts)");
}).ConfigurePrimaryHttpMessageHandler(sp => PublicNetworkGuard.Apply(
    new SocketsHttpHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 10 }, sp.GetRequiredService<IConfiguration>()));
builder.Services.AddHttpClient(PodcastDirectory.HttpClientName, client => client.Timeout = TimeSpan.FromSeconds(15));
builder.Services.AddSingleton<PodcastHttp>();
builder.Services.AddSingleton<PodcastDirectory>();
builder.Services.AddSingleton<PodcastAudioProcessor>();
builder.Services.AddSingleton<PodcastDownloadManager>();
builder.Services.AddSingleton<IPodcastWhisperRunner, WhisperCppRunner>();
builder.Services.AddSingleton<PodcastTranscriber>();
builder.Services.AddSingleton<IPodcastNotifier, PodcastPushNotifier>();
builder.Services.AddSingleton<PodcastService>();
builder.Services.AddSingleton<IPodcastAudioSource, PodcastAudioSource>();
builder.Services.AddHostedService<PodcastWorker>();

// ---- Accounts and sign-in ----
var accountStore = new SqliteAccountStore(dataRoot);
builder.Services.AddSingleton<IAccountStore>(accountStore);
// Persisted keys, or every restart would invalidate every outstanding session cookie.
builder.Services.AddDataProtection()
    .PersistKeysToFileSystem(new DirectoryInfo(Path.Combine(dataRoot, "keys")))
    .SetApplicationName("ReelHouse");
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.Cookie.Name = "reelhouse_session";
        options.ExpireTimeSpan = TimeSpan.FromDays(30);
        options.SlidingExpiration = true;
        options.SessionStore = accountStore;
        // An API, not an MVC app - never redirect to a login page, just report the status code
        // and let the web page and the apps react to it.
        options.Events.OnRedirectToLogin = context =>
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return Task.CompletedTask;
        };
        options.Events.OnRedirectToAccessDenied = context =>
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            return Task.CompletedTask;
        };
    });
builder.Services.AddAuthorization(options =>
    options.AddPolicy("AdminOnly", policy => policy.RequireRole(nameof(AccountRole.Admin))));
// Emails the owner on a failed sign-in, when LOGIN ALERTS is on - see LoginAlertSender.
builder.Services.AddSingleton<ILoginAlertSender, LoginAlertSender>();
// Records whether anything has reached this server from outside the LAN - see ExposureTracker.
builder.Services.AddSingleton<ExposureTracker>();

var app = builder.Build();

if (httpsEnabled)
    app.Logger.LogInformation("HTTPS on port {Port} using {Certificate}. Plain HTTP is still on port {HttpPort}.",
        httpsSettings.Port, httpsSettings.CertificatePath, httpPort);
else if (httpsSkipReason is not null)
    app.Logger.LogWarning("{Reason} Continuing on plain HTTP.", httpsSkipReason);
if (internetExposedEnabled)
    app.Logger.LogInformation("Internet Exposed Mode on port {Port} - login and HTTPS are always required there.", internetExposedSettings.Port);
else if (internetExposedSkipReason is not null)
    app.Logger.LogWarning("{Reason} Internet Exposed Mode is not active.", internetExposedSkipReason);
app.Logger.LogInformation("ReelHouse data folder: {DataRoot}", dataRoot);

app.UseMiddleware<ExposureWarningMiddleware>();

// Baseline browser hardening on every response.
app.Use((context, next) =>
{
    var headers = context.Response.Headers;
    headers.XContentTypeOptions = "nosniff";
    headers.XFrameOptions = "SAMEORIGIN";
    headers.ContentSecurityPolicy = "frame-ancestors 'self'";
    headers["Referrer-Policy"] = "same-origin";
    return next(context);
});

app.UseDefaultFiles();
// no-cache: keep it, but ask first - so an update's scripts are picked up straight away.
app.UseStaticFiles(new StaticFileOptions
{
    OnPrepareResponse = context => context.Context.Response.Headers.CacheControl = "no-cache"
});
app.UseAuthentication();
app.UseMiddleware<AuthGateMiddleware>();
app.UseAuthorization();
app.UseWebSockets();

app.MapSettingsEndpoints();
app.MapCertificateAuthorityEndpoints();
app.MapMediaEndpoints();
app.MapMediaDownloadEndpoints();
app.MapAudioEndpoints();
app.MapMusicEndpoints();
app.MapMusicDownloadEndpoints();
app.MapPodcastEndpoints();
app.MapPushEndpoints();
app.MapLicenseEndpoints();
app.MapSetupEndpoints();
app.MapAuthEndpoints();
app.MapAccountEndpoints();
app.MapLocalAddressEndpoints();

// Unauthenticated on purpose: "is it up, and what is it?" is the check the apps make before
// they know whether a login is needed.
app.MapGet("/api/health", () => Results.Ok(new
{
    status = "ok",
    product = "ReelHouse",
    build = BuildInfo.Current,
    timestamp = DateTimeOffset.UtcNow
}));

app.MapGet("/api/exposure/status", async (ExposureTracker tracker, AppSettingsFile settings, CancellationToken ct) =>
{
    var loginEnabled = await AuthSettingsDto.IsLoginRequiredAsync(settings, ct);
    return Results.Ok(new
    {
        externalRequestSeen = tracker.HasSeenExternalRequest,
        lastExternalAddress = tracker.LastExternalAddress,
        lastExternalAt = tracker.LastExternalAt,
        lastExternalViaProxy = tracker.LastExternalViaProxy,
        loginEnabled
    });
}).RequireAuthorization();

app.Run();

public partial class Program;
