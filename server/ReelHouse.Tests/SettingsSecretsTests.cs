
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using ReelHouse;
using Xunit;
using WebProgram = Program;

namespace ReelHouse.Tests;

// The masked-secret contract: GET /api/settings never returns a stored secret, and a save that
// sends the mask back untouched keeps what's stored. This is what makes it safe for phones and
// TVs to render the same settings forms the dashboard does.
public sealed class SettingsSecretsTests : IDisposable
{
    private readonly string _settingsPath;
    private readonly string _dataDirectory;

    public SettingsSecretsTests()
    {
        _dataDirectory = Path.Combine(Path.GetTempPath(), $"settings-secrets-{Guid.NewGuid():N}");
        Directory.CreateDirectory(_dataDirectory);
        _settingsPath = Path.Combine(_dataDirectory, "appsettings.json");
        File.WriteAllText(_settingsPath, WebHostTestSettings.LoginOffSettings);
    }

    public void Dispose()
    {
        try { TempDirectories.Delete(_dataDirectory); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private WebApplicationFactory<WebProgram> CreateFactory() => new WebApplicationFactory<WebProgram>()
        .WithWebHostBuilder(builder => builder
            .UseSetting("SettingsPath", _settingsPath)
            .UseSetting("DataDirectory", _dataDirectory)
                .UseSetting("Https:Enabled", "false")
                .UseSetting("Discovery:Enabled", "false"));

    [Fact]
    public async Task Get_MasksStoredSecrets_AndLeavesUnsetOnesEmpty()
    {
        var ct = TestContext.Current.CancellationToken;
        File.WriteAllText(_settingsPath, """
            { "Auth": { "Enabled": false },
              "Media": { "Enabled": true, "TmdbApiKey": "real-tmdb-key", "RescanHours": 6 },
              "Email": { "Enabled": false, "AppPassword": "" }
            }
            """);

        using var factory = CreateFactory();
        using var client = factory.CreateClient();

        using var response = await client.GetAsync("/api/settings", ct);
        var body = await response.Content.ReadAsStringAsync(ct);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        // The real key appears nowhere in the payload; the mask stands in for it.
        Assert.DoesNotContain("real-tmdb-key", body, StringComparison.Ordinal);
        using var document = JsonDocument.Parse(body);
        Assert.Equal(SettingsSecrets.Mask, document.RootElement.GetProperty("media").GetProperty("tmdbApiKey").GetString());

        // Unset secrets stay empty rather than masked - the form must be able to show the
        // difference between "configured" and "never set".
        Assert.Equal("", document.RootElement.GetProperty("email").GetProperty("appPassword").GetString());

        // Non-secret fields are untouched.
        Assert.Equal(6, document.RootElement.GetProperty("media").GetProperty("rescanHours").GetInt32());
    }

    [Fact]
    public async Task Save_WithTheMask_KeepsTheStoredSecret_AndStillSavesTheRest()
    {
        var ct = TestContext.Current.CancellationToken;
        File.WriteAllText(_settingsPath, """
            { "Auth": { "Enabled": false }, "Media": { "Enabled": true, "TmdbApiKey": "real-tmdb-key", "RescanHours": 6 } }
            """);

        using var factory = CreateFactory();
        using var client = factory.CreateClient();

        // What a client that edited only RescanHours sends back: the mask it was given, unchanged.
        using var save = await client.PutAsJsonAsync(
            "/api/settings/media", new { Enabled = true, TmdbApiKey = SettingsSecrets.Mask, RescanHours = 24 }, ct);
        Assert.Equal(HttpStatusCode.OK, save.StatusCode);

        var root = JsonNode.Parse(await File.ReadAllTextAsync(_settingsPath, ct))!.AsObject();
        Assert.Equal("real-tmdb-key", root["Media"]!["TmdbApiKey"]!.GetValue<string>());
        Assert.Equal(24, root["Media"]!["RescanHours"]!.GetValue<int>());
    }

    [Fact]
    public async Task Save_WithANewValue_ReplacesTheStoredSecret()
    {
        var ct = TestContext.Current.CancellationToken;
        File.WriteAllText(_settingsPath, """
            { "Auth": { "Enabled": false }, "Media": { "Enabled": true, "TmdbApiKey": "old-key", "RescanHours": 6 } }
            """);

        using var factory = CreateFactory();
        using var client = factory.CreateClient();

        using var save = await client.PutAsJsonAsync(
            "/api/settings/media", new { Enabled = true, TmdbApiKey = "new-key", RescanHours = 6 }, ct);
        Assert.Equal(HttpStatusCode.OK, save.StatusCode);

        var root = JsonNode.Parse(await File.ReadAllTextAsync(_settingsPath, ct))!.AsObject();
        Assert.Equal("new-key", root["Media"]!["TmdbApiKey"]!.GetValue<string>());
    }
}
