using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReelHouse;

// The push relay: how an install that bought ReelHouse gets notifications on the store-built apps
// without Apple or Google keys of its own. The relay (SentinelCore.PushRelay, push.nr5p.com) holds
// the keys for com.reelhouse.client and the ReelHouse Android app; this server proves it's
// licensed by sending its license file with every call, and the relay keeps each license's devices
// apart. Only a notification's title, text and what it opens pass through - see docs/PUSH.md.
//
// The wire shapes are SentinelCore's (PushRelayClient there); ReelHouse's own fields ride in
// "data", with the Android channel and the notification group alongside.
public sealed class PushRelayClient(IHttpClientFactory httpClientFactory, LicenseStore licenses, ILogger<PushRelayClient> logger)
{
    public const string HttpClientName = "ReelHousePushRelay";
    public const string LicenseHeader = "X-Sentinel-License";

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private sealed record RegisterBody(string Platform, string Token, string AppVariant, bool ApnsSandbox);
    private sealed record UnregisterBody(string Platform, string Token);
    private sealed record RelayMessage(
        string Title, string Body, string? EventId, string? EventType, bool Silent,
        Dictionary<string, string> Data, string AndroidChannel, string ThreadId);
    private sealed record PushBody(string Platform, string Token, string AppVariant, RelayMessage Message);
    private sealed record PushResult(string? Status);

    public static bool IsUsableUrl(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp);

    public async Task<bool> RegisterAsync(string relayUrl, PushDevice device, CancellationToken cancellationToken)
    {
        using var response = await PostAsync(relayUrl, "/v1/devices",
            new RegisterBody(device.Platform, device.Token, device.AppVariant, device.ApnsSandbox), cancellationToken);
        if (response is null) return false;
        if (response.IsSuccessStatusCode) return true;
        logger.LogWarning("The push relay refused to register {Device} ({Platform}): HTTP {Status} {Body}",
            device.DeviceName ?? "a device", device.Platform, (int)response.StatusCode, await ReadBodyAsync(response, cancellationToken));
        return false;
    }

    public async Task UnregisterAsync(string relayUrl, string platform, string token, CancellationToken cancellationToken)
    {
        using var response = await PostAsync(relayUrl, "/v1/devices/unregister", new UnregisterBody(platform, token), cancellationToken);
    }

    public async Task<PushAttempt> SendAsync(string relayUrl, PushDevice device, PushMessage message, CancellationToken cancellationToken)
    {
        var data = new Dictionary<string, string> { ["type"] = message.Type };
        if (message.ItemId is { Length: > 0 } item) data["itemId"] = item;
        if (message.PodcastId is { Length: > 0 } podcast) data["podcastId"] = podcast;
        var body = new PushBody(device.Platform, device.Token, device.AppVariant, new RelayMessage(
            message.Title, message.Body, message.ItemId, message.Type, false, data,
            PushTypes.AndroidChannel(message.Type), message.PodcastId ?? message.Type));

        using var response = await PostAsync(relayUrl, "/v1/push", body, cancellationToken);
        if (response is null) return PushAttempt.Failed;
        // The relay has never seen this device (registered before the relay was in use, or its
        // store was rebuilt): register it and try once more.
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            if (!await RegisterAsync(relayUrl, device, cancellationToken)) return PushAttempt.Failed;
            using var retry = await PostAsync(relayUrl, "/v1/push", body, cancellationToken);
            return retry is null ? PushAttempt.Failed : await ReadAttemptAsync(retry, device, cancellationToken);
        }
        return await ReadAttemptAsync(response, device, cancellationToken);
    }

    private async Task<PushAttempt> ReadAttemptAsync(HttpResponseMessage response, PushDevice device, CancellationToken cancellationToken)
    {
        if (!response.IsSuccessStatusCode)
        {
            logger.LogWarning("The push relay refused a push to {Device} ({Platform}): HTTP {Status} {Body}",
                device.DeviceName ?? "a device", device.Platform, (int)response.StatusCode, await ReadBodyAsync(response, cancellationToken));
            return PushAttempt.Failed;
        }
        PushResult? result = null;
        try { result = await response.Content.ReadFromJsonAsync<PushResult>(JsonOptions, cancellationToken); }
        catch (JsonException) { }
        return result?.Status?.ToLowerInvariant() switch
        {
            "delivered" => PushAttempt.Delivered,
            "unregistered" => PushAttempt.Unregistered,
            _ => PushAttempt.Failed
        };
    }

    private async Task<HttpResponseMessage?> PostAsync<T>(string relayUrl, string path, T body, CancellationToken cancellationToken)
    {
        if (!IsUsableUrl(relayUrl)) return null;
        if (await licenses.ReadAsync(cancellationToken) is not { } license) return null;

        var uri = new Uri(new Uri(relayUrl.TrimEnd('/') + "/"), path.TrimStart('/'));
        using var request = new HttpRequestMessage(HttpMethod.Post, uri) { Content = JsonContent.Create(body, options: JsonOptions) };
        request.Headers.TryAddWithoutValidation(LicenseHeader, Convert.ToBase64String(Encoding.UTF8.GetBytes(license.Contents)));
        try
        {
            return await httpClientFactory.CreateClient(HttpClientName).SendAsync(request, cancellationToken);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException && !cancellationToken.IsCancellationRequested)
        {
            logger.LogWarning(ex, "Could not reach the push relay at {Url}", relayUrl);
            return null;
        }
    }

    private static async Task<string> ReadBodyAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        var text = await response.Content.ReadAsStringAsync(cancellationToken);
        return text.Length <= 300 ? text : text[..300];
    }
}
