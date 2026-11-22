using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using ReelHouse;
using Xunit;
using WebProgram = Program;

namespace ReelHouse.Tests;

// Push notifications (docs/PUSH.md): who gets what, the switches, and what happens when Apple or
// Google answers that a token is wrong. Apple and Google are a fake HTTP handler; the keys are
// throwaway ones made per test, so the signing code really runs.
public sealed class PushNotificationTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"push-{Guid.NewGuid():N}");
    private readonly string _settingsPath;
    private readonly string _dataDirectory;
    private readonly FakePushServices _services = new();
    private readonly List<IDisposable> _disposables = [];

    public PushNotificationTests()
    {
        _dataDirectory = Path.Combine(_root, "data");
        Directory.CreateDirectory(_dataDirectory);
        _settingsPath = Path.Combine(_root, "appsettings.json");
        File.WriteAllText(_settingsPath, "{}");

        using (var ec = ECDsa.Create(ECCurve.NamedCurves.nistP256))
            File.WriteAllText(Path.Combine(_dataDirectory, "AuthKey_TEST.p8"), ec.ExportPkcs8PrivateKeyPem());
        using (var rsa = RSA.Create(2048))
            File.WriteAllText(Path.Combine(_dataDirectory, "firebase.json"), JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["client_email"] = "push@test.iam.gserviceaccount.com",
                ["private_key"] = rsa.ExportPkcs8PrivateKeyPem(),
                ["token_uri"] = "https://oauth2.googleapis.com/token"
            }));
    }

    public void Dispose()
    {
        foreach (var disposable in _disposables) disposable.Dispose();
        try { TempDirectories.Delete(_root); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static PushNotificationSettingsDto Keys(bool enabled = true) => new()
    {
        Enabled = enabled,
        AppleTeamId = "TEAM123456",
        AppleKeyId = "TEST",
        ApplePrivateKeyPath = "AuthKey_TEST.p8",
        FirebaseProjectId = "reelhouse-test",
        FirebaseServiceAccountPath = "firebase.json"
    };

    // A throwaway license signing key: licenses made with it verify against LicenseStore built
    // with its public half, exactly as real ones do against the embedded key.
    private static readonly RSA SigningKey = RSA.Create(2048);
    private static readonly string SigningPublicPem = SigningKey.ExportSubjectPublicKeyInfoPem();
    private const string RelayUrl = "https://relay.test";

    internal static string MakeLicense(RSA key, string product = "ReelHouse", string customer = "Test Household")
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(
            new LicenseInfo(customer, "test@example.com", product, Guid.NewGuid(), DateTimeOffset.UtcNow),
            new JsonSerializerOptions(JsonSerializerDefaults.Web));
        var signature = key.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
        return JsonSerializer.Serialize(new { payload = Convert.ToBase64String(payload), signature = Convert.ToBase64String(signature) });
    }

    private LicenseStore Licenses() => new(Path.Combine(_dataDirectory, LicenseStore.FileName), SigningPublicPem);

    private async Task<(PushNotifier Notifier, PushDeviceStore Devices)> CreateAsync(PushNotificationSettingsDto settings, IAccountStore? accounts = null)
    {
        var settingsFile = new AppSettingsFile(_settingsPath);
        await settingsFile.MergeSectionAsync(PushNotificationSettingsDto.SectionName, settings, Ct);
        var devices = new PushDeviceStore(_dataDirectory);
        _disposables.Add(devices);
        var notifier = new PushNotifier(settingsFile, devices, accounts ?? new EmptyAccounts(),
            new ApnsSender(_services, NullLogger<ApnsSender>.Instance), new FcmSender(_services, NullLogger<FcmSender>.Instance),
            new PushRelayClient(_services, Licenses(), NullLogger<PushRelayClient>.Instance), Licenses(),
            _dataDirectory, NullLogger<PushNotifier>.Instance);
        return (notifier, devices);
    }

    private static readonly PushMessage Episode = new("The Show", "Episode 12", PushTypes.Podcast, "ep-1", "show-1");

    [Fact]
    public async Task A_new_episode_reaches_only_the_followers_phones()
    {
        var (notifier, devices) = await CreateAsync(Keys());
        await devices.UpsertAsync("apple", "aaaa", "Ann's iPhone", "ios", false, "ann", Ct);
        await devices.UpsertAsync("android", "bbbb", "Bob's Pixel", "android", false, "bob", Ct);
        await devices.UpsertAsync("android", "cccc", "Ann's tablet", "android", false, "ann", Ct);

        var report = await notifier.NotifyUsersAsync(PushCategory.NewEpisodes, ["Ann"], Episode, Ct);

        Assert.Equal(new PushDeliveryReport(2, 2, 0, 0), report);
        Assert.Equal(["aaaa"], _services.AppleTokens);
        Assert.Equal(["cccc"], _services.FirebaseTokens);
        var apple = _services.AppleBodies.Single();
        Assert.Equal("podcast", apple.GetProperty("type").GetString());
        Assert.Equal("ep-1", apple.GetProperty("itemId").GetString());
        Assert.Equal("show-1", apple.GetProperty("podcastId").GetString());
        Assert.Equal("Episode 12", apple.GetProperty("aps").GetProperty("alert").GetProperty("body").GetString());
        var android = _services.FirebaseBodies.Single().GetProperty("message");
        Assert.Equal("new_episodes", android.GetProperty("android").GetProperty("notification").GetProperty("channel_id").GetString());
        Assert.Equal("show-1", android.GetProperty("data").GetProperty("podcastId").GetString());
    }

    [Fact]
    public async Task With_login_off_everyone_is_the_household()
    {
        var (notifier, devices) = await CreateAsync(Keys());
        await devices.UpsertAsync("apple", "aaaa", null, "ios", false, "", Ct);
        await devices.UpsertAsync("apple", "dddd", null, "ios", false, "ann", Ct);

        var report = await notifier.NotifyUsersAsync(PushCategory.Downloads, [""], Episode, Ct);

        Assert.Equal(2, report.Delivered);
    }

    [Fact]
    public async Task Nothing_is_sent_while_off_or_with_that_kind_switched_off()
    {
        var (notifier, devices) = await CreateAsync(Keys(enabled: false));
        await devices.UpsertAsync("apple", "aaaa", null, "ios", false, "", Ct);
        Assert.Equal(PushDeliveryReport.None, await notifier.NotifyUsersAsync(PushCategory.NewEpisodes, [""], Episode, Ct));

        var settings = Keys();
        settings.NewEpisodes = false;
        (notifier, _) = await CreateAsync(settings);
        Assert.Equal(PushDeliveryReport.None, await notifier.NotifyUsersAsync(PushCategory.NewEpisodes, [""], Episode, Ct));
        Assert.Equal(1, (await notifier.NotifyUsersAsync(PushCategory.Downloads, [""], Episode, Ct)).Delivered);
        Assert.Single(_services.AppleTokens);
    }

    [Fact]
    public async Task The_Apple_TV_and_a_platform_with_no_keys_are_skipped()
    {
        var settings = Keys();
        settings.FirebaseProjectId = "";
        var (notifier, devices) = await CreateAsync(settings);
        await devices.UpsertAsync("apple", "tv01", "Living Room", "tvos", false, "", Ct);
        await devices.UpsertAsync("android", "bbbb", null, "android", false, "", Ct);

        Assert.Equal(PushDeliveryReport.None, await notifier.NotifyUsersAsync(PushCategory.Downloads, [""], Episode, Ct));
        Assert.Empty(_services.Requests);
    }

    [Fact]
    public async Task A_token_from_the_other_Apple_environment_is_retried_there_and_remembered()
    {
        var (notifier, devices) = await CreateAsync(Keys());
        await devices.UpsertAsync("apple", "aaaa", null, "ios", false, "", Ct);
        _services.ProductionRejects = "BadDeviceToken";

        var report = await notifier.NotifyUsersAsync(PushCategory.Downloads, [""], Episode, Ct);

        Assert.Equal(1, report.Delivered);
        Assert.Equal(["api.push.apple.com", "api.sandbox.push.apple.com"], _services.AppleHosts);
        Assert.True((await devices.GetAllAsync(Ct)).Single().ApnsSandbox);
    }

    [Fact]
    public async Task A_dead_token_is_dropped()
    {
        var (notifier, devices) = await CreateAsync(Keys());
        await devices.UpsertAsync("android", "gone", null, "android", false, "", Ct);
        _services.FirebaseRejects = """{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}""";

        var report = await notifier.NotifyUsersAsync(PushCategory.Downloads, [""], Episode, Ct);

        Assert.Equal(new PushDeliveryReport(1, 0, 1, 1), report);
        Assert.Empty(await devices.GetAllAsync(Ct));
    }

    [Fact]
    public async Task Sign_in_alerts_go_to_admins_only()
    {
        var accounts = new FixedAccounts(("Owner", AccountRole.Admin), ("kid", AccountRole.Viewer));
        var (notifier, devices) = await CreateAsync(Keys(), accounts);
        await devices.UpsertAsync("apple", "aaaa", null, "ios", false, "owner", Ct);
        await devices.UpsertAsync("apple", "kkkk", null, "ios", false, "kid", Ct);

        await notifier.NotifyAdminsAsync(PushCategory.LoginAlerts, new PushMessage("Failed sign-in", "x", PushTypes.Login), Ct);

        Assert.Equal(["aaaa"], _services.AppleTokens);
    }

    [Fact]
    public async Task Registering_again_updates_the_same_row()
    {
        var (_, devices) = await CreateAsync(Keys());
        var first = await devices.UpsertAsync("Apple", " aaaa ", "Old name", "ios", false, "ann", Ct);
        var second = await devices.UpsertAsync("apple", "aaaa", "New name", "ios", true, "bob", Ct);

        var only = Assert.Single(await devices.GetAllAsync(Ct));
        Assert.Equal(first.Id, second.Id);
        Assert.Equal(("New name", true, "bob"), (only.DeviceName, only.ApnsSandbox, only.Username));
    }

    [Theory]
    [InlineData("movie", 2024, null, null, "Dune (2024)", "Downloaded and ready to watch.")]
    [InlineData("episode", null, 2, 5, "Severance", "Season 2, episode 5 is ready to watch.")]
    [InlineData("episode", null, 3, null, "Severance", "Season 3 is ready to watch.")]
    public void A_finished_download_says_what_is_ready(string kind, int? year, int? season, int? episode, string title, string body)
    {
        var message = MediaDownloadManager.FinishedMessage(new MediaDownload
        {
            Kind = kind, Title = kind == "movie" ? "Dune" : "Severance", Year = year, Season = season, Episode = episode
        });
        Assert.Equal((title, body, PushTypes.Download), (message.Title, message.Body, message.Type));
    }

    [Fact]
    public void Half_filled_keys_are_reported()
    {
        var settings = new PushNotificationSettingsDto { AppleTeamId = "TEAM", FirebaseProjectId = "p", FirebaseServiceAccountPath = "missing.json" };
        var problems = PushCredentials.Problems(settings, _dataDirectory);
        Assert.Contains(problems, p => p.StartsWith("Apple needs all three"));
        Assert.Contains(problems, p => p.Contains("missing.json"));
        Assert.Null(PushCredentials.Apple(settings, _dataDirectory));
    }

    private static PushNotificationSettingsDto RelayOnly(bool enabled = true) =>
        new() { Enabled = enabled, RelayEnabled = true, RelayUrl = RelayUrl };

    [Fact]
    public async Task Without_keys_a_licensed_server_sends_through_the_relay()
    {
        await Licenses().SaveAsync(MakeLicense(SigningKey), Ct);
        var (notifier, devices) = await CreateAsync(RelayOnly());
        await devices.UpsertAsync("apple", "aaaa", "iPhone", "ios", true, "ann", Ct);
        await devices.UpsertAsync("android", "fid-1", "Pixel", "android", false, "ann", Ct);

        var report = await notifier.NotifyUsersAsync(PushCategory.NewEpisodes, ["ann"], Episode, Ct);

        Assert.Equal(2, report.Delivered);
        Assert.Empty(_services.Requests); // nothing went to Apple or Google directly
        var pushes = _services.RelayCalls.Where(c => c.Path == "/v1/push").ToList();
        Assert.Equal(2, pushes.Count);
        Assert.All(pushes, p => Assert.False(string.IsNullOrEmpty(p.License)));
        var android = pushes.Single(p => p.Body.GetProperty("platform").GetString() == "android").Body.GetProperty("message");
        Assert.Equal("new_episodes", android.GetProperty("androidChannel").GetString());
        Assert.Equal("show-1", android.GetProperty("data").GetProperty("podcastId").GetString());
        Assert.Equal("ep-1", android.GetProperty("data").GetProperty("itemId").GetString());
        Assert.Equal("podcast", android.GetProperty("data").GetProperty("type").GetString());
    }

    [Fact]
    public async Task A_device_the_relay_has_never_seen_is_registered_and_retried()
    {
        await Licenses().SaveAsync(MakeLicense(SigningKey), Ct);
        var (notifier, devices) = await CreateAsync(RelayOnly());
        await devices.UpsertAsync("apple", "aaaa", null, "ios", true, "", Ct);
        _services.RelayForgetsDevicesOnce = true;

        var report = await notifier.NotifyUsersAsync(PushCategory.Downloads, [""], Episode, Ct);

        Assert.Equal(1, report.Delivered);
        Assert.Equal(["/v1/push", "/v1/devices", "/v1/push"], _services.RelayCalls.Select(c => c.Path));
        Assert.True(_services.RelayCalls[1].Body.GetProperty("apnsSandbox").GetBoolean());
    }

    [Fact]
    public async Task No_license_means_no_relay()
    {
        var (notifier, devices) = await CreateAsync(RelayOnly());
        await devices.UpsertAsync("apple", "aaaa", null, "ios", false, "", Ct);

        Assert.Equal(PushDeliveryReport.None, await notifier.NotifyUsersAsync(PushCategory.Downloads, [""], Episode, Ct));
        Assert.Empty(_services.RelayCalls);
        var routes = await notifier.RoutesAsync(RelayOnly(), Ct);
        Assert.Equal((PushRoute.None, PushRoute.None, false), routes);
    }

    [Fact]
    public async Task Own_keys_win_over_the_relay()
    {
        await Licenses().SaveAsync(MakeLicense(SigningKey), Ct);
        var settings = Keys();
        settings.FirebaseProjectId = "";
        settings.RelayUrl = RelayUrl;
        var (notifier, _) = await CreateAsync(settings);

        var routes = await notifier.RoutesAsync(settings, Ct);

        Assert.Equal((PushRoute.Direct, PushRoute.Relay, true), routes);
    }

    [Fact]
    public void Only_a_genuine_ReelHouse_license_is_accepted()
    {
        var store = Licenses();
        Assert.NotNull(store.Verify(MakeLicense(SigningKey)));
        Assert.Null(store.Verify(MakeLicense(SigningKey, product: "SentinelCore")));
        using var otherKey = RSA.Create(2048);
        Assert.Null(store.Verify(MakeLicense(otherKey)));
        Assert.Null(store.Verify("not a license"));
        var tampered = JsonDocument.Parse(MakeLicense(SigningKey)).RootElement;
        var forged = JsonSerializer.Serialize(new
        {
            payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new LicenseInfo("Mallory", "m@x", "ReelHouse", Guid.NewGuid(), DateTimeOffset.UtcNow))),
            signature = tampered.GetProperty("signature").GetString()
        });
        Assert.Null(store.Verify(forged));
    }

    // ---- Through the real host ----

    private HttpClient CreateClient(PushNotificationSettingsDto settings)
    {
        File.WriteAllText(_settingsPath, JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["Auth"] = new { Enabled = false },
            [PushNotificationSettingsDto.SectionName] = settings
        }));
        var factory = new WebApplicationFactory<WebProgram>().WithWebHostBuilder(builder => builder
            .UseTestSettings(_settingsPath, _dataDirectory)
            .ConfigureTestServices(services =>
                services.AddHttpClient(PushSenderHelpers.HttpClientName).ConfigurePrimaryHttpMessageHandler(() => _services.Handler)));
        _disposables.Add(factory);
        var client = factory.CreateClient();
        _disposables.Add(client);
        return client;
    }

    [Fact]
    public async Task A_phone_registers_and_the_test_button_reaches_it()
    {
        var client = CreateClient(Keys(enabled: false));

        using (var register = await client.PostAsJsonAsync("/api/push/devices",
                   new { platform = "apple", token = "abcd", deviceName = "iPhone", appVariant = "ios", apnsSandbox = true }, Ct))
            Assert.Equal(HttpStatusCode.OK, register.StatusCode);

        var status = await client.GetFromJsonAsync<JsonElement>("/api/push/status", Ct);
        Assert.False(status.GetProperty("enabled").GetBoolean());
        Assert.True(status.GetProperty("appleConfigured").GetBoolean());
        Assert.Equal(1, status.GetProperty("myDevices").GetInt32());

        using var test = await client.PostAsync("/api/push/test", null, Ct);
        var body = await test.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal(HttpStatusCode.OK, test.StatusCode);
        Assert.Equal(1, body.GetProperty("delivered").GetInt32());
        Assert.Contains("still switched off", body.GetProperty("message").GetString());
        Assert.Equal(["api.sandbox.push.apple.com"], _services.AppleHosts);
        Assert.Equal("test", _services.AppleBodies.Single().GetProperty("type").GetString());

        using (var unregister = await client.PostAsJsonAsync("/api/push/devices/unregister", new { platform = "apple", token = "abcd" }, Ct))
            Assert.Equal(HttpStatusCode.OK, unregister.StatusCode);
        using var again = await client.PostAsync("/api/push/test", null, Ct);
        Assert.Equal(HttpStatusCode.BadRequest, again.StatusCode);
    }

    [Fact]
    public async Task The_test_button_explains_when_no_keys_are_set()
    {
        var client = CreateClient(new PushNotificationSettingsDto { Enabled = true });
        using var test = await client.PostAsync("/api/push/test", null, Ct);
        var body = await test.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal(HttpStatusCode.BadRequest, test.StatusCode);
        Assert.Contains("PUSH NOTIFICATIONS", body.GetProperty("error").GetString());
    }

    [Fact]
    public async Task A_bad_registration_is_refused()
    {
        var client = CreateClient(Keys());
        using var response = await client.PostAsJsonAsync("/api/push/devices", new { platform = "windows", token = "" }, Ct);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Saving_the_section_warns_about_a_missing_key_file()
    {
        var client = CreateClient(new PushNotificationSettingsDto());
        var settings = Keys();
        settings.ApplePrivateKeyPath = "/nowhere/AuthKey.p8";
        using var response = await client.PutAsJsonAsync("/api/settings/push", settings, Ct);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("/nowhere/AuthKey.p8", body.GetProperty("warnings")[0].GetString());
    }

    [Fact]
    public async Task A_file_that_is_not_a_license_is_refused_and_nothing_is_saved()
    {
        var client = CreateClient(Keys());
        using var install = await client.PostAsync("/api/license/install", new StringContent(MakeLicense(SigningKey)), Ct);
        // Signed with a throwaway key, so the real embedded key rightly refuses it.
        Assert.Equal(HttpStatusCode.BadRequest, install.StatusCode);
        Assert.False(File.Exists(Path.Combine(_dataDirectory, LicenseStore.FileName)));
        var status = await client.GetFromJsonAsync<JsonElement>("/api/license/status", Ct);
        Assert.False(status.GetProperty("valid").GetBoolean());
    }

    // Stands in for Apple, Google's sign-in and FCM.
    private sealed class FakePushServices : IHttpClientFactory
    {
        public readonly List<(Uri Uri, string Body)> Requests = [];
        public string? ProductionRejects;
        public string? FirebaseRejects;
        public HttpMessageHandler Handler { get; }

        public FakePushServices() => Handler = new Stub(this);

        public HttpClient CreateClient(string name) => new(Handler, disposeHandler: false);

        public List<string> AppleHosts => Requests.Where(r => r.Uri.Host.Contains("push.apple.com")).Select(r => r.Uri.Host).ToList();
        public List<string> AppleTokens => Requests.Where(r => r.Uri.Host.Contains("push.apple.com") && Sent(r)).Select(r => r.Uri.Segments[^1]).ToList();
        public List<JsonElement> AppleBodies => Requests.Where(r => r.Uri.Host.Contains("push.apple.com")).Select(r => JsonDocument.Parse(r.Body).RootElement).ToList();
        public List<JsonElement> FirebaseBodies => Requests.Where(r => r.Uri.Host == "fcm.googleapis.com").Select(r => JsonDocument.Parse(r.Body).RootElement).ToList();
        public List<string> FirebaseTokens => FirebaseBodies.Select(b => b.GetProperty("message").GetProperty("fid").GetString()!).ToList();
        public List<(string Path, JsonElement Body, string? License)> RelayCalls { get; } = [];
        public bool RelayForgetsDevicesOnce;

        private bool Sent((Uri Uri, string Body) request) => !(request.Uri.Host == "api.push.apple.com" && ProductionRejects is not null);

        private sealed class Stub(FakePushServices owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
                var host = request.RequestUri!.Host;
                if (host == "relay.test")
                {
                    var license = request.Headers.TryGetValues("X-Sentinel-License", out var values) ? values.First() : null;
                    lock (owner.RelayCalls) owner.RelayCalls.Add((request.RequestUri.AbsolutePath, JsonDocument.Parse(body).RootElement.Clone(), license));
                    if (request.RequestUri.AbsolutePath == "/v1/push" && owner.RelayForgetsDevicesOnce)
                    {
                        owner.RelayForgetsDevicesOnce = false;
                        return Json(HttpStatusCode.NotFound, """{"status":"unknown"}""");
                    }
                    return Json(HttpStatusCode.OK, request.RequestUri.AbsolutePath == "/v1/push" ? """{"status":"delivered"}""" : """{"registered":true}""");
                }
                lock (owner.Requests) owner.Requests.Add((request.RequestUri!, body));
                if (host == "oauth2.googleapis.com")
                    return Json(HttpStatusCode.OK, """{"access_token":"ya29.test","expires_in":3600}""");
                if (host == "api.push.apple.com" && owner.ProductionRejects is { } reason)
                    return Json(HttpStatusCode.BadRequest, $$"""{"reason":"{{reason}}"}""");
                if (host == "fcm.googleapis.com" && owner.FirebaseRejects is { } error)
                    return Json(HttpStatusCode.NotFound, error);
                return Json(HttpStatusCode.OK, "{}");
            }

            private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
                new(status) { Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json") };
        }
    }

    private sealed class FixedAccounts(params (string Name, AccountRole Role)[] people) : IAccountStore
    {
        private readonly EmptyAccounts _empty = new();
        public Task<IReadOnlyList<Account>> GetAllAsync(CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<Account>>(people.Select(p => new Account(Guid.NewGuid(), p.Name, "", p.Role, null, DateTimeOffset.UtcNow)).ToList());
        public Task<Account?> GetByUsernameAsync(string username, CancellationToken cancellationToken) => _empty.GetByUsernameAsync(username, cancellationToken);
        public Task<Account?> GetByIdAsync(Guid id, CancellationToken cancellationToken) => _empty.GetByIdAsync(id, cancellationToken);
        public Task<Account> CreateAsync(string username, string passwordHash, AccountRole role, string? displayName, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<bool> UpdateRoleAsync(Guid id, AccountRole role, CancellationToken cancellationToken) => Task.FromResult(false);
        public Task<bool> UpdatePasswordAsync(Guid id, string passwordHash, CancellationToken cancellationToken) => Task.FromResult(false);
        public Task<bool> UpdateEmailAsync(Guid id, string? email, CancellationToken cancellationToken) => Task.FromResult(false);
        public Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken) => Task.FromResult(false);
        public Task RestoreAsync(Account account, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task InvalidateForAccountAsync(Guid accountId, CancellationToken cancellationToken) => Task.CompletedTask;
        public Task InvalidateAllAsync(CancellationToken cancellationToken) => Task.CompletedTask;
        public Task<bool> AnyAccountsExistAsync(CancellationToken cancellationToken) => Task.FromResult(people.Length > 0);
    }
}
