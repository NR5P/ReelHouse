using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReelHouse;

// The two delivery services a push goes through: Apple's (APNs) for the iPhone and Apple TV apps,
// Google's (Firebase Cloud Messaging) for the Android app. Ported from SentinelCore's senders,
// trimmed to what ReelHouse sends and with no relay: the server holds the keys itself (see
// docs/PUSH.md). Both are singletons so their sign-in tokens are cached between pushes.

public static class PushPlatforms
{
    public const string Apple = "apple";
    public const string Android = "android";

    public static bool IsSupported(string? value) =>
        string.Equals(value, Apple, StringComparison.OrdinalIgnoreCase) ||
        string.Equals(value, Android, StringComparison.OrdinalIgnoreCase);

    public static string Normalize(string value) => value.Trim().ToLowerInvariant();
}

// What tapping the notification opens, and how the phone files it. The apps switch on Type.
public static class PushTypes
{
    public const string Podcast = "podcast";
    public const string Download = "download";
    public const string Login = "login";
    public const string Server = "server";
    public const string Alarm = "alarm";
    public const string Test = "test";

    // The Android notification channel each type goes to: people can mute one kind in Android's
    // own settings without muting the rest. The app creates these channels.
    public static string AndroidChannel(string type) => type switch
    {
        Podcast => "new_episodes",
        Download => "downloads",
        Login or Server => "account",
        _ => "general"
    };
}

public sealed record PushMessage(
    string Title,
    string Body,
    string Type,
    // The podcast episode, or the movie/show in the library, the notification is about.
    string? ItemId = null,
    // For a new episode: the show it belongs to, so the app can open the show's page.
    string? PodcastId = null)
{
    public static PushMessage Test() => new(
        "ReelHouse test",
        "Push notifications are working on this device.",
        PushTypes.Test);
}

public enum PushAttempt
{
    Delivered,
    Failed,
    // The service says this token will never work again (APNs 410 / FCM UNREGISTERED): the
    // device's registration is dropped. The app registers again the next time it's opened.
    Unregistered,
    // APNs only: the token belongs to the other environment (a development build's token sent to
    // production, or the other way round). The dispatcher retries on the other one.
    WrongEnvironment
}

internal static class PushSenderHelpers
{
    public const string HttpClientName = "ReelHousePush";

    public static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static string? TryReadJsonProperty(string json, string propertyName)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.TryGetProperty(propertyName, out var value) ? value.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string Truncate(string value, int maximumLength) =>
        value.Length <= maximumLength ? value : value[..maximumLength];
}

public sealed class ApnsSender(IHttpClientFactory httpClientFactory, ILogger<ApnsSender> logger)
{
    private readonly SemaphoreSlim _tokenLock = new(1, 1);
    private string? _token;
    private string? _tokenIdentity;
    private DateTimeOffset _tokenCreatedAt;

    public async Task<PushAttempt> SendAsync(
        PushCredentials.AppleKey key,
        bool sandbox,
        string deviceToken,
        string topic,
        PushMessage message,
        CancellationToken cancellationToken)
    {
        var providerToken = await GetProviderTokenAsync(key, cancellationToken);
        var host = sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
        var payload = new Dictionary<string, object?>
        {
            ["aps"] = new Dictionary<string, object?>
            {
                ["alert"] = new { title = message.Title, body = message.Body },
                ["sound"] = "default",
                // Groups them in Notification Centre: episodes with episodes, downloads with downloads.
                ["thread-id"] = message.PodcastId ?? message.Type
            },
            ["type"] = message.Type,
            ["itemId"] = message.ItemId,
            ["podcastId"] = message.PodcastId
        };
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{host}/3/device/{Uri.EscapeDataString(deviceToken)}")
        {
            Version = HttpVersion.Version20,
            VersionPolicy = HttpVersionPolicy.RequestVersionExact,
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("bearer", providerToken);
        request.Headers.TryAddWithoutValidation("apns-topic", topic);
        request.Headers.TryAddWithoutValidation("apns-push-type", "alert");
        request.Headers.TryAddWithoutValidation("apns-priority", "10");

        using var response = await httpClientFactory.CreateClient(PushSenderHelpers.HttpClientName).SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) return PushAttempt.Delivered;

        var reason = PushSenderHelpers.TryReadJsonProperty(await response.Content.ReadAsStringAsync(cancellationToken), "reason");
        if (string.Equals(reason, "BadDeviceToken", StringComparison.OrdinalIgnoreCase)) return PushAttempt.WrongEnvironment;
        logger.LogWarning("Apple refused a push with HTTP {StatusCode}: {Reason}", (int)response.StatusCode, reason ?? "unknown");
        return response.StatusCode == HttpStatusCode.Gone || string.Equals(reason, "Unregistered", StringComparison.OrdinalIgnoreCase)
            ? PushAttempt.Unregistered
            : PushAttempt.Failed;
    }

    // Apple wants a JWT signed with the team's .p8 key, refreshed at most every 20 minutes and at
    // least every hour; 50 minutes keeps inside both.
    private async Task<string> GetProviderTokenAsync(PushCredentials.AppleKey key, CancellationToken cancellationToken)
    {
        var identity = $"{key.TeamId}|{key.KeyId}|{key.PrivateKeyPath}";
        if (_token is not null && identity == _tokenIdentity && DateTimeOffset.UtcNow - _tokenCreatedAt < TimeSpan.FromMinutes(50))
            return _token;

        await _tokenLock.WaitAsync(cancellationToken);
        try
        {
            if (_token is not null && identity == _tokenIdentity && DateTimeOffset.UtcNow - _tokenCreatedAt < TimeSpan.FromMinutes(50))
                return _token;

            var privateKey = await File.ReadAllTextAsync(key.PrivateKeyPath, cancellationToken);
            var header = PushSenderHelpers.Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { alg = "ES256", kid = key.KeyId }));
            var claims = PushSenderHelpers.Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { iss = key.TeamId, iat = DateTimeOffset.UtcNow.ToUnixTimeSeconds() }));
            var unsigned = $"{header}.{claims}";
            using var ecdsa = ECDsa.Create();
            ecdsa.ImportFromPem(privateKey);
            var signature = ecdsa.SignData(Encoding.ASCII.GetBytes(unsigned), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

            _token = $"{unsigned}.{PushSenderHelpers.Base64Url(signature)}";
            _tokenIdentity = identity;
            _tokenCreatedAt = DateTimeOffset.UtcNow;
            return _token;
        }
        finally
        {
            _tokenLock.Release();
        }
    }
}

public sealed class FcmSender(IHttpClientFactory httpClientFactory, ILogger<FcmSender> logger)
{
    private readonly SemaphoreSlim _tokenLock = new(1, 1);
    private string? _token;
    private string? _tokenIdentity;
    private DateTimeOffset _tokenExpiresAt;

    public async Task<PushAttempt> SendAsync(PushCredentials.FirebaseKey key, string deviceToken, PushMessage message, CancellationToken cancellationToken)
    {
        var accessToken = await GetAccessTokenAsync(key, cancellationToken);
        var body = JsonSerializer.Serialize(new
        {
            message = new
            {
                // The app registers its Firebase Installation ID (FirebaseMessaging.register()), as
                // SentinelCore's does, so direct and relayed pushes address a phone the same way.
                fid = deviceToken,
                notification = new { title = message.Title, body = message.Body },
                // Repeated in data: with the app open, Android hands the message to the app
                // instead of showing it, and the app builds the notification from these.
                data = new Dictionary<string, string>
                {
                    ["type"] = message.Type,
                    ["itemId"] = message.ItemId ?? string.Empty,
                    ["podcastId"] = message.PodcastId ?? string.Empty,
                    ["title"] = message.Title,
                    ["body"] = message.Body
                },
                android = new
                {
                    priority = "high",
                    notification = new
                    {
                        channel_id = PushTypes.AndroidChannel(message.Type),
                        sound = "default",
                        // A newer notification about the same thing replaces the older one.
                        tag = message.ItemId is { Length: > 0 } item ? $"{message.Type}-{item}" : message.Type
                    }
                }
            }
        });
        using var request = new HttpRequestMessage(HttpMethod.Post,
            $"https://fcm.googleapis.com/v1/projects/{Uri.EscapeDataString(key.ProjectId)}/messages:send")
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json")
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

        using var response = await httpClientFactory.CreateClient(PushSenderHelpers.HttpClientName).SendAsync(request, cancellationToken);
        if (response.IsSuccessStatusCode) return PushAttempt.Delivered;

        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
        logger.LogWarning("Firebase refused a push with HTTP {StatusCode}: {Response}", (int)response.StatusCode, PushSenderHelpers.Truncate(responseBody, 500));
        return responseBody.Contains("UNREGISTERED", StringComparison.OrdinalIgnoreCase) ||
               (response.StatusCode == HttpStatusCode.NotFound && responseBody.Contains("NOT_FOUND", StringComparison.OrdinalIgnoreCase))
            ? PushAttempt.Unregistered
            : PushAttempt.Failed;
    }

    // An OAuth access token from the service account: a JWT signed with its private key, swapped
    // at Google for a token good for an hour.
    private async Task<string> GetAccessTokenAsync(PushCredentials.FirebaseKey key, CancellationToken cancellationToken)
    {
        var identity = $"{key.ProjectId}|{key.ServiceAccountPath}";
        if (_token is not null && identity == _tokenIdentity && DateTimeOffset.UtcNow < _tokenExpiresAt - TimeSpan.FromMinutes(5))
            return _token;

        await _tokenLock.WaitAsync(cancellationToken);
        try
        {
            if (_token is not null && identity == _tokenIdentity && DateTimeOffset.UtcNow < _tokenExpiresAt - TimeSpan.FromMinutes(5))
                return _token;

            await using var stream = File.OpenRead(key.ServiceAccountPath);
            var account = await JsonSerializer.DeserializeAsync<ServiceAccount>(stream, cancellationToken: cancellationToken)
                ?? throw new InvalidOperationException("The Firebase service-account file is not valid JSON.");
            if (string.IsNullOrWhiteSpace(account.ClientEmail) || string.IsNullOrWhiteSpace(account.PrivateKey))
                throw new InvalidOperationException("The Firebase service-account file is missing client_email or private_key.");

            var tokenUri = string.IsNullOrWhiteSpace(account.TokenUri) ? "https://oauth2.googleapis.com/token" : account.TokenUri;
            var issuedAt = DateTimeOffset.UtcNow;
            var header = PushSenderHelpers.Base64Url(JsonSerializer.SerializeToUtf8Bytes(new { alg = "RS256", typ = "JWT" }));
            var claims = PushSenderHelpers.Base64Url(JsonSerializer.SerializeToUtf8Bytes(new
            {
                iss = account.ClientEmail,
                scope = "https://www.googleapis.com/auth/firebase.messaging",
                aud = tokenUri,
                iat = issuedAt.ToUnixTimeSeconds(),
                exp = issuedAt.AddMinutes(55).ToUnixTimeSeconds()
            }));
            var unsigned = $"{header}.{claims}";
            using var rsa = RSA.Create();
            rsa.ImportFromPem(account.PrivateKey);
            var signature = rsa.SignData(Encoding.ASCII.GetBytes(unsigned), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);

            using var request = new HttpRequestMessage(HttpMethod.Post, tokenUri)
            {
                Content = new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["grant_type"] = "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    ["assertion"] = $"{unsigned}.{PushSenderHelpers.Base64Url(signature)}"
                })
            };
            using var response = await httpClientFactory.CreateClient(PushSenderHelpers.HttpClientName).SendAsync(request, cancellationToken);
            var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException($"Google refused the Firebase service account (HTTP {(int)response.StatusCode}): {PushSenderHelpers.Truncate(responseBody, 300)}");

            var token = JsonSerializer.Deserialize<TokenResponse>(responseBody);
            if (string.IsNullOrWhiteSpace(token?.AccessToken))
                throw new InvalidOperationException("Google did not return an access token for the Firebase service account.");

            _token = token.AccessToken;
            _tokenIdentity = identity;
            _tokenExpiresAt = issuedAt.AddSeconds(Math.Max(60, token.ExpiresIn));
            return _token;
        }
        finally
        {
            _tokenLock.Release();
        }
    }

    private sealed class ServiceAccount
    {
        [JsonPropertyName("client_email")] public string ClientEmail { get; init; } = string.Empty;
        [JsonPropertyName("private_key")] public string PrivateKey { get; init; } = string.Empty;
        [JsonPropertyName("token_uri")] public string TokenUri { get; init; } = string.Empty;
    }

    private sealed class TokenResponse
    {
        [JsonPropertyName("access_token")] public string AccessToken { get; init; } = string.Empty;
        [JsonPropertyName("expires_in")] public int ExpiresIn { get; init; } = 3600;
    }
}
