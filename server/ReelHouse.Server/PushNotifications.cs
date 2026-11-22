using System.ComponentModel.DataAnnotations;
using Microsoft.Data.Sqlite;

namespace ReelHouse;

// Push notifications to the ReelHouse apps: what is sent (new podcast episodes, finished
// downloads, failed sign-ins, server problems, a missed wake-up alarm), to whom, and the switches
// that control it. User guide: docs/PUSH.md. The Settings -> PUSH NOTIFICATIONS section is
// PushNotificationSettingsDto. A platform is reached either directly with Apple's/Google's keys
// filled in here (a self-built install), or - with no keys - through the ReelHouse push relay,
// which needs a ReelHouse license (Settings -> LICENSE). Keys win where both are possible.

public sealed class PushNotificationSettingsDto
{
    public const string SectionName = "PushNotifications";

    // On by default: with a license installed, a purchased install has notifications with nothing
    // to set up.
    public bool Enabled { get; set; } = true;

    // What to send. Each is a separate switch so a household can keep, say, download pushes and
    // drop the rest. Per-show "Notify me of new episodes" still applies on top of NewEpisodes.
    public bool NewEpisodes { get; set; } = true;
    public bool Downloads { get; set; } = true;
    public bool LoginAlerts { get; set; } = true;
    public bool ServerAlerts { get; set; } = true;
    public bool WakeAlarms { get; set; } = true;

    // Apple (iPhone). One .p8 key works for every app in the team, so the bundle id is only the
    // address on the envelope.
    [MaxLength(20)] public string AppleTeamId { get; set; } = string.Empty;
    [MaxLength(20)] public string AppleKeyId { get; set; } = string.Empty;
    public string ApplePrivateKeyPath { get; set; } = string.Empty;
    public string AppleBundleId { get; set; } = "com.reelhouse.client";

    // Google (Android).
    public string FirebaseProjectId { get; set; } = string.Empty;
    public string FirebaseServiceAccountPath { get; set; } = string.Empty;

    // The ReelHouse push relay, for a platform with no keys above. Needs a ReelHouse license.
    public bool RelayEnabled { get; set; } = true;
    public string RelayUrl { get; set; } = DefaultRelayUrl;

    public const string DefaultRelayUrl = "https://push.nr5p.com";
}

// How a platform's pushes go out: straight to Apple/Google with this server's own keys, through
// the relay, or not at all.
public enum PushRoute { None, Direct, Relay }

// The keys a push is sent with, read off the settings. Null for a platform whose fields aren't all
// filled in: that platform is simply skipped.
public static class PushCredentials
{
    public sealed record AppleKey(string TeamId, string KeyId, string PrivateKeyPath, string BundleId);
    public sealed record FirebaseKey(string ProjectId, string ServiceAccountPath);

    public static AppleKey? Apple(PushNotificationSettingsDto settings, string dataRoot) =>
        string.IsNullOrWhiteSpace(settings.AppleTeamId) || string.IsNullOrWhiteSpace(settings.AppleKeyId) ||
        string.IsNullOrWhiteSpace(settings.ApplePrivateKeyPath) || string.IsNullOrWhiteSpace(settings.AppleBundleId)
            ? null
            : new AppleKey(settings.AppleTeamId.Trim(), settings.AppleKeyId.Trim(), Resolve(settings.ApplePrivateKeyPath, dataRoot), settings.AppleBundleId.Trim());

    public static FirebaseKey? Firebase(PushNotificationSettingsDto settings, string dataRoot) =>
        string.IsNullOrWhiteSpace(settings.FirebaseProjectId) || string.IsNullOrWhiteSpace(settings.FirebaseServiceAccountPath)
            ? null
            : new FirebaseKey(settings.FirebaseProjectId.Trim(), Resolve(settings.FirebaseServiceAccountPath, dataRoot));

    // A bare file name is looked for in the data folder, which is where docs/PUSH.md says to put it.
    private static string Resolve(string path, string dataRoot)
    {
        path = path.Trim();
        if (path.StartsWith("~/", StringComparison.Ordinal))
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[2..]);
        return Path.IsPathRooted(path) ? path : Path.Combine(dataRoot, path);
    }

    // Problems with the saved keys a person can fix, for the settings form and the status line.
    public static List<string> Problems(PushNotificationSettingsDto settings, string dataRoot)
    {
        var problems = new List<string>();
        var appleFilled = new[] { settings.AppleTeamId, settings.AppleKeyId, settings.ApplePrivateKeyPath }.Count(v => !string.IsNullOrWhiteSpace(v));
        if (appleFilled is > 0 and < 3)
            problems.Add("Apple needs all three of Team ID, Key ID and Key File - iPhones get nothing until they're all filled in.");
        if (Apple(settings, dataRoot) is { } apple && !File.Exists(apple.PrivateKeyPath))
            problems.Add($"Apple key file {apple.PrivateKeyPath} isn't there (or this service can't read it).");
        var firebaseFilled = new[] { settings.FirebaseProjectId, settings.FirebaseServiceAccountPath }.Count(v => !string.IsNullOrWhiteSpace(v));
        if (firebaseFilled == 1)
            problems.Add("Firebase needs both the Project ID and the Service Account File - Android phones get nothing until both are filled in.");
        if (Firebase(settings, dataRoot) is { } firebase && !File.Exists(firebase.ServiceAccountPath))
            problems.Add($"Firebase service-account file {firebase.ServiceAccountPath} isn't there (or this service can't read it).");
        return problems;
    }
}

public enum PushCategory { NewEpisodes, Downloads, LoginAlerts, ServerAlerts, WakeAlarms, Test }

public sealed record PushDevice(
    Guid Id,
    string Platform,
    string Token,
    string? DeviceName,
    // "ios", "tvos" or "android".
    string AppVariant,
    // Apple only: a build installed from Xcode registers a token for Apple's sandbox, an App Store
    // or TestFlight build one for production. The app says which; the dispatcher corrects it if
    // Apple disagrees.
    bool ApnsSandbox,
    // Lower-cased username of whoever was signed in when the app registered; "" with login off.
    string Username,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

public sealed class PushDeviceStore : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly SemaphoreSlim _lock = new(1, 1);

    public PushDeviceStore(string dataDirectory)
    {
        Directory.CreateDirectory(dataDirectory);
        _connection = new SqliteConnection($"Data Source={Path.Combine(dataDirectory, "push-devices.db")}");
        _connection.Open();
        using var command = _connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode=WAL;
            PRAGMA busy_timeout=5000;
            CREATE TABLE IF NOT EXISTS PushDevices (
                Id TEXT PRIMARY KEY,
                Platform TEXT NOT NULL,
                Token TEXT NOT NULL,
                DeviceName TEXT,
                AppVariant TEXT NOT NULL,
                ApnsSandbox INTEGER NOT NULL DEFAULT 0,
                Username TEXT NOT NULL DEFAULT '',
                CreatedAt TEXT NOT NULL,
                UpdatedAt TEXT NOT NULL,
                UNIQUE (Platform, Token)
            );
            """;
        command.ExecuteNonQuery();
    }

    // A phone registers on every launch; the same token just refreshes its row (and moves it to
    // whoever is signed in now).
    public async Task<PushDevice> UpsertAsync(string platform, string token, string? deviceName, string appVariant, bool apnsSandbox, string username, CancellationToken cancellationToken)
    {
        platform = PushPlatforms.Normalize(platform);
        token = token.Trim();
        var now = DateTimeOffset.UtcNow;
        await _lock.WaitAsync(cancellationToken);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText = """
                INSERT INTO PushDevices (Id, Platform, Token, DeviceName, AppVariant, ApnsSandbox, Username, CreatedAt, UpdatedAt)
                VALUES ($id, $platform, $token, $name, $variant, $sandbox, $user, $now, $now)
                ON CONFLICT (Platform, Token) DO UPDATE SET
                    DeviceName = excluded.DeviceName, AppVariant = excluded.AppVariant, ApnsSandbox = excluded.ApnsSandbox,
                    Username = excluded.Username, UpdatedAt = excluded.UpdatedAt;
                """;
            command.Parameters.AddWithValue("$id", Guid.NewGuid().ToString());
            command.Parameters.AddWithValue("$platform", platform);
            command.Parameters.AddWithValue("$token", token);
            command.Parameters.AddWithValue("$name", (object?)deviceName ?? DBNull.Value);
            command.Parameters.AddWithValue("$variant", appVariant);
            command.Parameters.AddWithValue("$sandbox", apnsSandbox ? 1 : 0);
            command.Parameters.AddWithValue("$user", username.Trim().ToLowerInvariant());
            command.Parameters.AddWithValue("$now", now.ToString("O"));
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        finally
        {
            _lock.Release();
        }
        return (await GetAllAsync(cancellationToken)).First(d => d.Platform == platform && d.Token == token);
    }

    public async Task<IReadOnlyList<PushDevice>> GetAllAsync(CancellationToken cancellationToken)
    {
        await _lock.WaitAsync(cancellationToken);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText = "SELECT Id, Platform, Token, DeviceName, AppVariant, ApnsSandbox, Username, CreatedAt, UpdatedAt FROM PushDevices ORDER BY UpdatedAt DESC;";
            using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var devices = new List<PushDevice>();
            while (await reader.ReadAsync(cancellationToken))
            {
                devices.Add(new PushDevice(
                    Guid.Parse(reader.GetString(0)), reader.GetString(1), reader.GetString(2),
                    reader.IsDBNull(3) ? null : reader.GetString(3), reader.GetString(4), reader.GetInt64(5) != 0,
                    reader.GetString(6), DateTimeOffset.Parse(reader.GetString(7)), DateTimeOffset.Parse(reader.GetString(8))));
            }
            return devices;
        }
        finally
        {
            _lock.Release();
        }
    }

    public Task RemoveAsync(string platform, string token, CancellationToken cancellationToken) =>
        ExecuteAsync("DELETE FROM PushDevices WHERE Platform = $platform AND Token = $token;", cancellationToken,
            ("$platform", PushPlatforms.Normalize(platform)), ("$token", token.Trim()));

    public Task SetSandboxAsync(Guid id, bool sandbox, CancellationToken cancellationToken) =>
        ExecuteAsync("UPDATE PushDevices SET ApnsSandbox = $sandbox WHERE Id = $id;", cancellationToken,
            ("$sandbox", sandbox ? 1 : 0), ("$id", id.ToString()));

    // An account deleted or renamed: its phones stop getting that person's notifications.
    public Task RemoveUserAsync(string username, CancellationToken cancellationToken) =>
        ExecuteAsync("DELETE FROM PushDevices WHERE Username = $user;", cancellationToken, ("$user", username.ToLowerInvariant()));

    private async Task ExecuteAsync(string sql, CancellationToken cancellationToken, params (string Name, object Value)[] parameters)
    {
        await _lock.WaitAsync(cancellationToken);
        try
        {
            using var command = _connection.CreateCommand();
            command.CommandText = sql;
            foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        finally
        {
            _lock.Release();
        }
    }

    public void Dispose()
    {
        _connection.Dispose();
        _lock.Dispose();
    }
}

public sealed record PushDeliveryReport(int Attempted, int Delivered, int Failed, int Removed)
{
    public static readonly PushDeliveryReport None = new(0, 0, 0, 0);
}

// What the rest of the server calls. Every method checks the switches itself, so a caller just
// says what happened and to whom.
public interface IPushNotifier
{
    // userKeys: lower-cased usernames, or "" (login off) meaning every registered device.
    Task<PushDeliveryReport> NotifyUsersAsync(PushCategory category, IReadOnlyCollection<string> userKeys, PushMessage message, CancellationToken cancellationToken);

    // Admin accounts' devices: sign-in alerts and problems with the server itself.
    Task<PushDeliveryReport> NotifyAdminsAsync(PushCategory category, PushMessage message, CancellationToken cancellationToken);
}

public sealed class PushNotifier(
    AppSettingsFile settings,
    PushDeviceStore devices,
    IAccountStore accounts,
    ApnsSender apns,
    FcmSender fcm,
    PushRelayClient relay,
    LicenseStore licenses,
    string dataRoot,
    ILogger<PushNotifier> logger) : IPushNotifier
{
    // Where a key file given as a bare name is looked for.
    public string DataRoot => dataRoot;

    public async Task<PushNotificationSettingsDto> ReadSettingsAsync(CancellationToken cancellationToken) =>
        await settings.GetSectionAsync<PushNotificationSettingsDto>(PushNotificationSettingsDto.SectionName, cancellationToken) ?? new();

    // Keys first; the relay only for a platform without them, and only with a license installed.
    public async Task<(PushRoute Apple, PushRoute Android, bool Licensed)> RoutesAsync(PushNotificationSettingsDto options, CancellationToken cancellationToken)
    {
        var licensed = await licenses.ReadAsync(cancellationToken) is not null;
        var relayUsable = options.RelayEnabled && licensed && PushRelayClient.IsUsableUrl(options.RelayUrl);
        PushRoute For(bool direct) => direct ? PushRoute.Direct : relayUsable ? PushRoute.Relay : PushRoute.None;
        return (For(PushCredentials.Apple(options, dataRoot) is not null), For(PushCredentials.Firebase(options, dataRoot) is not null), licensed);
    }

    // A phone just registered or unregistered here: tell the relay too when that's how its pushes
    // go, so the first push doesn't need the register-and-retry. Never awaited by the request.
    public async Task ForwardRegistrationAsync(PushDevice device, bool remove)
    {
        try
        {
            var options = await ReadSettingsAsync(CancellationToken.None);
            var routes = await RoutesAsync(options, CancellationToken.None);
            var route = device.Platform == PushPlatforms.Apple ? routes.Apple : routes.Android;
            if (route != PushRoute.Relay || device.AppVariant == "tvos") return;
            if (remove) await relay.UnregisterAsync(options.RelayUrl, device.Platform, device.Token, CancellationToken.None);
            else await relay.RegisterAsync(options.RelayUrl, device, CancellationToken.None);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Passing a device {What} on to the push relay failed", remove ? "removal" : "registration");
        }
    }

    public static bool Allows(PushNotificationSettingsDto options, PushCategory category) => options.Enabled && category switch
    {
        PushCategory.NewEpisodes => options.NewEpisodes,
        PushCategory.Downloads => options.Downloads,
        PushCategory.LoginAlerts => options.LoginAlerts,
        PushCategory.ServerAlerts => options.ServerAlerts,
        PushCategory.WakeAlarms => options.WakeAlarms,
        _ => true
    };

    public async Task<PushDeliveryReport> NotifyUsersAsync(PushCategory category, IReadOnlyCollection<string> userKeys, PushMessage message, CancellationToken cancellationToken)
    {
        if (userKeys.Count == 0) return PushDeliveryReport.None;
        var everyone = userKeys.Contains("");
        var wanted = userKeys.Select(k => k.ToLowerInvariant()).ToHashSet();
        return await SendAsync(category, message, d => everyone || wanted.Contains(d.Username), cancellationToken);
    }

    public async Task<PushDeliveryReport> NotifyAdminsAsync(PushCategory category, PushMessage message, CancellationToken cancellationToken)
    {
        var all = await accounts.GetAllAsync(cancellationToken);
        // No accounts yet means login is off: whoever has the app is the owner.
        if (all.Count == 0) return await SendAsync(category, message, _ => true, cancellationToken);
        var admins = all.Where(a => a.Role == AccountRole.Admin).Select(a => a.Username.ToLowerInvariant()).ToHashSet();
        return await SendAsync(category, message, d => admins.Contains(d.Username), cancellationToken);
    }

    private async Task<PushDeliveryReport> SendAsync(PushCategory category, PushMessage message, Func<PushDevice, bool> recipients, CancellationToken cancellationToken)
    {
        var options = await ReadSettingsAsync(cancellationToken);
        if (!Allows(options, category)) return PushDeliveryReport.None;
        try
        {
            var report = await DeliverAsync(options, message, recipients, cancellationToken);
            if (report.Attempted > 0)
                logger.LogInformation("Push ({Category}) \"{Title}\": {Delivered}/{Attempted} delivered", category, message.Title, report.Delivered, report.Attempted);
            return report;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // A push is never worth failing what triggered it (a download being filed, a feed refresh).
            logger.LogWarning(ex, "Push ({Category}) \"{Title}\" failed", category, message.Title);
            return PushDeliveryReport.None;
        }
    }

    // Sends regardless of Enabled - for the test button, which has to work before the switch is
    // trusted - but still only to devices the keys can reach.
    public async Task<PushDeliveryReport> DeliverAsync(PushNotificationSettingsDto options, PushMessage message, Func<PushDevice, bool> recipients, CancellationToken cancellationToken)
    {
        var apple = PushCredentials.Apple(options, dataRoot);
        var firebase = PushCredentials.Firebase(options, dataRoot);
        var routes = await RoutesAsync(options, cancellationToken);
        int attempted = 0, delivered = 0, failed = 0, removed = 0;

        foreach (var device in (await devices.GetAllAsync(cancellationToken)).Where(recipients))
        {
            cancellationToken.ThrowIfCancellationRequested();
            // tvOS can't show a notification banner, so there's nothing to send a TV.
            if (device.AppVariant == "tvos") continue;
            var route = device.Platform == PushPlatforms.Apple ? routes.Apple : routes.Android;
            if (route == PushRoute.None) continue;

            attempted++;
            PushAttempt attempt;
            try
            {
                if (route == PushRoute.Relay)
                {
                    attempt = await relay.SendAsync(options.RelayUrl, device, message, cancellationToken);
                }
                else if (device.Platform == PushPlatforms.Apple)
                {
                    attempt = await apns.SendAsync(apple!, device.ApnsSandbox, device.Token, apple!.BundleId, message, cancellationToken);
                    if (attempt == PushAttempt.WrongEnvironment)
                    {
                        // The app guessed its environment wrong (or was reinstalled from the
                        // other kind of build): try the other one and remember the answer.
                        attempt = await apns.SendAsync(apple!, !device.ApnsSandbox, device.Token, apple!.BundleId, message, cancellationToken);
                        if (attempt == PushAttempt.Delivered) await devices.SetSandboxAsync(device.Id, !device.ApnsSandbox, cancellationToken);
                        else if (attempt == PushAttempt.WrongEnvironment) attempt = PushAttempt.Unregistered;
                    }
                }
                else
                {
                    attempt = await fcm.SendAsync(firebase!, device.Token, message, cancellationToken);
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogWarning(ex, "Push to {Platform} device {Device} failed", device.Platform, device.DeviceName ?? device.Id.ToString());
                attempt = PushAttempt.Failed;
            }

            if (attempt == PushAttempt.Delivered)
            {
                delivered++;
                continue;
            }
            failed++;
            if (attempt == PushAttempt.Unregistered)
            {
                await devices.RemoveAsync(device.Platform, device.Token, cancellationToken);
                removed++;
                logger.LogWarning("Dropped the push registration for {Device} ({Platform}): the service says its token no longer works. " +
                                  "It registers again the next time the app is opened.", device.DeviceName ?? "unnamed device", device.Platform);
            }
        }
        return new PushDeliveryReport(attempted, delivered, failed, removed);
    }
}
