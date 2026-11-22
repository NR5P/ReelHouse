using System.Security.Cryptography;
using System.Text.Json;

namespace ReelHouse;

// A ReelHouse license: the same signed .lic format and signing key as SentinelCore's (issued with
// SentinelCore's LicenseGenerator, Product "ReelHouse"). Perpetual, not tied to a machine, and
// never a gate on the app itself - what it unlocks is the push relay (docs/PUSH.md), which is how
// a purchased install gets notifications on the App Store / Play Store apps without Apple or
// Google keys of its own. A SentinelCore license is not accepted here: it's a different product.
public sealed record LicenseInfo(string CustomerName, string CustomerEmail, string Product, Guid LicenseId, DateTimeOffset IssuedAt);

public sealed class LicenseStore(string path, string publicKeyPem = LicenseStore.PublicKeyPem)
{
    public const string ProductName = "ReelHouse";
    public const string FileName = "license.lic";

    // The public half of the shared license signing key (SentinelCore.Licensing.LicensePublicKey).
    // The private half never leaves the machine the licenses are issued on.
    public const string PublicKeyPem = """
        -----BEGIN PUBLIC KEY-----
        MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAoP5AaxG6j2hLHQvG7seg
        WGg4zFznO6LSdcz5oWRHFzuNF8LigifsJ/RLPeJnwNBgnt0CodfkZ/E0CSc1Hpx9
        kYMZLZQ48jaSIlxmLL4Zt2teGYTGHkDac/6VLyPVQESKjZPZ7V5GMsFf5mupz6zC
        pAAcVslomeBASvrW+23gxuMnXcJ7aFClkJlnfmRq2H1zpwBU+opHYdplgq+Vr7Xg
        nIvGxbFn8v7zj3f9aATmtWwbuPWNjCeZHFLrv6nnQoVgWcc9i5HAWT/1Wv1UYqfW
        obrXx6U+YFiVoRuAW+b/eVpJEoQPw4zU1D6jNldJTqcoNOrV5jMcte/zcao0AKuj
        gQRZ2gb+qXdao2rpAfczGFZlCEvucT/ZtCPb+jQVlv7qgrCPA7DYXG87fE/Yqzlt
        G52WeZZ0G/EHp2kJljcNaCg//4P9nASAnqhLuj0xDLJMuAN700FC4b/RZvaQ2CB2
        s97CzJ/AlJvqfymwsgjQQUqpH5lLUq5zOuSXYbyPxdXNAgMBAAE=
        -----END PUBLIC KEY-----
        """;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public string Path => path;

    // Re-read on every call: dropping a license in works without a restart.
    public async Task<(LicenseInfo Info, string Contents)?> ReadAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(path)) return null;
        try
        {
            var contents = await File.ReadAllTextAsync(path, cancellationToken);
            return Verify(contents) is { } info ? (info, contents) : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    // Null for anything that isn't a genuine ReelHouse license - forged, edited, garbled, or for
    // another product. Never throws.
    public LicenseInfo? Verify(string contents)
    {
        var info = VerifySignature(contents, publicKeyPem);
        return info is not null && string.Equals(info.Product, ProductName, StringComparison.OrdinalIgnoreCase) ? info : null;
    }

    public static LicenseInfo? VerifySignature(string contents, string publicKeyPem)
    {
        try
        {
            var envelope = JsonSerializer.Deserialize<Envelope>(contents, JsonOptions);
            if (string.IsNullOrEmpty(envelope?.Payload) || string.IsNullOrEmpty(envelope.Signature)) return null;
            var payload = Convert.FromBase64String(envelope.Payload);
            var signature = Convert.FromBase64String(envelope.Signature);
            using var key = RSA.Create();
            key.ImportFromPem(publicKeyPem);
            // Verified before a single field of the payload is trusted.
            if (!key.VerifyData(payload, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)) return null;
            return JsonSerializer.Deserialize<LicenseInfo>(payload, JsonOptions);
        }
        catch (Exception ex) when (ex is JsonException or FormatException or CryptographicException or ArgumentException)
        {
            return null;
        }
    }

    public async Task SaveAsync(string contents, CancellationToken cancellationToken)
    {
        var temporary = path + ".tmp";
        await File.WriteAllTextAsync(temporary, contents, cancellationToken);
        AtomicFile.Replace(temporary, path);
    }

    private sealed record Envelope(string Payload, string Signature);
}

public static class LicenseEndpoints
{
    public static void MapLicenseEndpoints(this WebApplication app)
    {
        // Any signed-in account: the apps' Notifications screens say whether the push service is
        // available, and the license holder's name is not a secret from their own household.
        app.MapGet("/api/license/status", async (LicenseStore licenses, CancellationToken ct) =>
            await licenses.ReadAsync(ct) is { } license
                ? Results.Ok(new { valid = true, customerName = license.Info.CustomerName, product = license.Info.Product, issuedAt = license.Info.IssuedAt })
                : Results.Ok(new { valid = false })).RequireAuthorization();

        // The raw .lic contents (uploaded from the browser). Checked before it's written, so a
        // wrong file can never replace a license that was working.
        app.MapPost("/api/license/install", async (HttpRequest request, LicenseStore licenses, CancellationToken ct) =>
        {
            using var reader = new StreamReader(request.Body);
            var contents = await reader.ReadToEndAsync(ct);
            if (contents.Length > 64 * 1024) return Results.BadRequest(new { error = "That file is far too big to be a license - nothing was changed." });
            var info = licenses.Verify(contents);
            if (info is null)
            {
                var other = LicenseStore.VerifySignature(contents, LicenseStore.PublicKeyPem);
                return Results.BadRequest(new
                {
                    error = other is not null
                        ? $"That is a {other.Product} license, not a ReelHouse one - nothing was changed."
                        : "That file doesn't look like a valid ReelHouse license - nothing was changed."
                });
            }
            await licenses.SaveAsync(contents, ct);
            return Results.Ok(new { valid = true, customerName = info.CustomerName });
        }).RequireAuthorization("AdminOnly");
    }
}
