using System.ComponentModel.DataAnnotations;
using System.Net.Mail;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Mvc;

namespace ReelHouse;

// Every user-editable settings section, in one place: what GET /api/settings returns.
public sealed record SettingsSnapshot(
    EmailSettingsDto? Email = null,
    LoginAlertSettingsDto? LoginAlerts = null,
    LoggingSettingsDto? Logging = null,
    ServerSettingsDto? Server = null,
    MediaSettingsDto? Media = null,
    MediaDownloadsSettingsDto? MediaDownloads = null,
    MusicSettingsDto? Music = null,
    PodcastSettingsDto? Podcasts = null,
    PushNotificationSettingsDto? PushNotifications = null);

public static class SettingsEndpoints
{
    public sealed record RestartRequest(string? Service);

    public static void MapSettingsEndpoints(this WebApplication app)
    {
        // Every route here - including the GET - is Admin-only: the settings snapshot contains
        // SMTP passwords and API keys, so even read access isn't safe for a Viewer.
        var settings = app.MapGroup("/api/settings").RequireAuthorization("AdminOnly");

        settings.MapGet("", async (AppSettingsFile appSettings, CancellationToken ct) =>
        {
            // Secrets go out masked - a settings form only ever needs to know a secret is set,
            // never what it is.
            var snapshot = await BuildSnapshotAsync(appSettings, ct);
            SettingsSecrets.MaskInPlace(snapshot);
            return Results.Ok(snapshot);
        });

        // What the sections and fields *are*, as opposed to what they're currently set to. Every
        // client renders its settings forms from this rather than hard-coding its own copy - see
        // SettingsSchema.
        settings.MapGet("/schema", () => Results.Ok(SettingsSchema.Sections));

        settings.MapPut("/email", async (EmailSettingsDto dto, AppSettingsFile appSettings, CancellationToken ct) =>
            await SaveSectionAsync(dto, appSettings, "Email", ct, extra =>
            {
                if (!dto.Enabled) return;
                // Deliberately the same call the server makes at startup, so a form that saves
                // cleanly here can never be a config the service then refuses to boot on.
                if (SmtpMailer.ValidateDeliverable(dto.ToOptions()) is { } problem) extra.Add(problem);
            }));

        // Saved even with a key file missing - it may be copied in afterwards - but the form is
        // told, so a typo in a path doesn't look like a working setup.
        settings.MapPut("/push", async (PushNotificationSettingsDto dto, AppSettingsFile appSettings, PushNotifier notifier, CancellationToken ct) =>
        {
            dto.AppleTeamId = dto.AppleTeamId?.Trim() ?? string.Empty;
            dto.AppleKeyId = dto.AppleKeyId?.Trim() ?? string.Empty;
            dto.ApplePrivateKeyPath = dto.ApplePrivateKeyPath?.Trim() ?? string.Empty;
            dto.AppleBundleId = string.IsNullOrWhiteSpace(dto.AppleBundleId) ? "com.reelhouse.client" : dto.AppleBundleId.Trim();
            dto.FirebaseProjectId = dto.FirebaseProjectId?.Trim() ?? string.Empty;
            dto.FirebaseServiceAccountPath = dto.FirebaseServiceAccountPath?.Trim() ?? string.Empty;
            dto.RelayUrl = string.IsNullOrWhiteSpace(dto.RelayUrl) ? PushNotificationSettingsDto.DefaultRelayUrl : dto.RelayUrl.Trim();
            var result = await SaveSectionAsync(dto, appSettings, PushNotificationSettingsDto.SectionName, ct, errors =>
            {
                if (dto.RelayEnabled && !PushRelayClient.IsUsableUrl(dto.RelayUrl))
                    errors.Add("Push Service Address must be a web address starting with https://.");
            });
            var problems = PushCredentials.Problems(dto, notifier.DataRoot);
            return problems.Count == 0 || result is not IStatusCodeHttpResult { StatusCode: 200 }
                ? result
                : Results.Ok(new { success = true, warnings = problems });
        });

        settings.MapPut("/login-alerts", async (LoginAlertSettingsDto dto, AppSettingsFile appSettings, CancellationToken ct) =>
            await SaveSectionAsync(dto, appSettings, "LoginAlerts", ct));

        settings.MapPut("/media", async (MediaSettingsDto dto, AppSettingsFile appSettings, CancellationToken ct) =>
        {
            dto.TmdbApiKey = dto.TmdbApiKey?.Trim() ?? string.Empty;
            return await SaveSectionAsync(dto, appSettings, MediaSettingsDto.SectionName, ct);
        });

        // Music.
        settings.MapPut("/music", async (MusicSettingsDto dto, AppSettingsFile appSettings, CancellationToken ct) =>
            await SaveSectionAsync(dto, appSettings, MusicSettingsDto.SectionName, ct));
        // ---- Podcasts ----
        settings.MapPut("/podcasts", async (PodcastSettingsDto dto, AppSettingsFile appSettings, CancellationToken ct) =>
        {
            dto.DownloadFolder = dto.DownloadFolder?.Trim() ?? string.Empty;
            dto.DirectoryCountry = dto.DirectoryCountry?.Trim().ToLowerInvariant() ?? "us";
            dto.WhisperCommand = string.IsNullOrWhiteSpace(dto.WhisperCommand) ? "whisper-cli" : dto.WhisperCommand.Trim();
            dto.WhisperModel = dto.WhisperModel?.Trim() ?? string.Empty;
            return await SaveSectionAsync(dto, appSettings, PodcastSettingsDto.SectionName, ct, extra =>
            {
                if (PodcastLocations.ValidateDownloadFolder(dto.DownloadFolder) is { } folderProblem) extra.Add(folderProblem);
                if (dto.DirectoryCountry.Length != 2 || !dto.DirectoryCountry.All(char.IsAsciiLetterLower))
                    extra.Add("Directory Country is a two-letter country code, like us or gb.");
            });
        });
        // ---- end Podcasts ----

        // MOVIE DOWNLOADS -> Mullvad Location's list (SettingsOptionsSourceSchema contract).
        settings.MapGet("/media-downloads/mullvad-locations", async (MediaVpnConfig vpn, CancellationToken ct) =>
        {
            try { return Results.Ok(new { options = await vpn.MullvadLocationsAsync(ct) }); }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
            {
                return Results.Json(new { error = "Could not fetch Mullvad's server list: " + ex.Message }, statusCode: StatusCodes.Status502BadGateway);
            }
        });

        settings.MapPut("/media-downloads", async (MediaDownloadsSettingsDto dto, AppSettingsFile appSettings, CancellationToken ct) =>
        {
            dto.ProwlarrUrl = dto.ProwlarrUrl?.Trim() ?? string.Empty;
            dto.QbittorrentUrl = dto.QbittorrentUrl?.Trim() ?? string.Empty;
            dto.ProwlarrApiKey = dto.ProwlarrApiKey?.Trim() ?? string.Empty;
            dto.QbittorrentUsername = dto.QbittorrentUsername?.Trim() ?? string.Empty;
            dto.VpnProvider = dto.VpnProvider?.Trim().ToLowerInvariant() ?? MediaVpnProviders.Installed;
            dto.MullvadLocation = dto.MullvadLocation?.Trim().ToLowerInvariant() ?? "se";
            dto.WireGuardAddress = dto.WireGuardAddress?.Trim() ?? string.Empty;
            dto.WireGuardDns = dto.WireGuardDns?.Trim() ?? string.Empty;
            dto.WireGuardServerPublicKey = dto.WireGuardServerPublicKey?.Trim() ?? string.Empty;
            dto.WireGuardServerEndpoint = dto.WireGuardServerEndpoint?.Trim() ?? string.Empty;
            // Secrets arrive masked when unchanged; judge them after SaveSectionAsync unmasks them.
            return await SaveSectionAsync(dto, appSettings, MediaDownloadsSettingsDto.SectionName, ct, extra =>
            {
                extra.AddRange(MediaVpnConfig.Validate(dto));
                if (dto.AllowedUsers is not ("admins" or "everyone")) extra.Add("Who Can Add must be admins or everyone.");
                if (dto.PreferredQuality is not ("720p" or "1080p" or "2160p" or MediaDownloadsSettingsDto.QualityAny))
                    extra.Add("Preferred Quality must be 720p, 1080p, 2160p or any.");
                foreach (var (label, url) in new[] { ("Prowlarr Address", dto.ProwlarrUrl), ("qBittorrent Address", dto.QbittorrentUrl) })
                    if (url.Length > 0 && (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")))
                        extra.Add($"{label} must be a web address like http://10.251.0.2:8080.");
            });
        });

        // Logging lives at Logging.LogLevel with a dotted category name ("Microsoft.AspNetCore")
        // that a flat schema field path can't carry - see LoggingSettingsDto. Mapped by hand
        // here; WriteLoggingAsync preserves any extra categories added to the file directly.
        settings.MapPut("/logging", async (LoggingSettingsDto dto, AppSettingsFile appSettings, CancellationToken ct) =>
        {
            var errors = new List<string>();
            foreach (var (label, value) in new[] { ("Default", dto.Default), ("Microsoft.AspNetCore", dto.MicrosoftAspNetCore) })
            {
                if (!LogLevelNames.Contains(value))
                    errors.Add($"{label} must be one of: {string.Join(", ", LogLevelNames)}.");
            }
            if (errors.Count > 0) return Results.BadRequest(new { errors });

            await WriteLoggingAsync(dto, appSettings, ct);
            return Results.Ok(new { saved = true });
        });

        // "Urls" is a bare string at the root of appsettings.json, not a section - the only save
        // here that doesn't go through MergeSectionAsync. Kestrel binds it once at startup, so
        // this is saved-but-pending until the server restarts, same contract as Internet
        // Exposed Mode below.
        settings.MapPut("/server", async (ServerSettingsDto dto, AppSettingsFile appSettings, CancellationToken ct) =>
        {
            var errors = ValidateDataAnnotations(dto);
            var parts = dto.Urls.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (parts.Length == 0)
                errors.Add("At least one listen address is required, e.g. http://0.0.0.0:3350.");
            foreach (var part in parts)
            {
                // Kestrel accepts wildcard hosts (http://*:3350, http://+:3350) that Uri can't
                // parse - swap them for a placeholder so the rest of the address still gets
                // checked.
                var parseable = part.Replace("//*:", "//wildcard-host:").Replace("//+:", "//wildcard-host:");
                if (!Uri.TryCreate(parseable, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
                    errors.Add($"'{part}' is not a valid http(s) listen address.");
            }
            if (errors.Count > 0) return Results.BadRequest(new { errors });

            await appSettings.ReplaceSectionAsync("Urls", dto.Urls, ct);
            return Results.Ok(new { saved = true, restartRequired = true });
        });

        // Lives in this project's own appsettings.json (a keyed AppSettingsFile instance
        // registered separately in Program.cs), not the main app's shared settings file - it
        // configures this project's own Kestrel binding, the same category as the Https block
        // it depends on. Takes effect after a restart, like Https already does.
        settings.MapGet("/internet-exposed", async (
            [FromKeyedServices("web")] AppSettingsFile webSettings,
            InternetExposedSettings active,
            CancellationToken ct) =>
        {
            var dto = await webSettings.GetSectionAsync<InternetExposedSettingsDto>("InternetExposed", ct)
                ?? new InternetExposedSettingsDto();
            return Results.Ok(new { dto.Enabled, dto.Port, active = active.Enabled, activePort = active.Port });
        });

        settings.MapPut("/internet-exposed", async (
            InternetExposedSettingsDto dto,
            [FromKeyedServices("web")] AppSettingsFile webSettings,
            IConfiguration configuration,
            IAccountStore accounts,
            CancellationToken ct) =>
        {
            var errors = await ValidateInternetExposedAsync(dto, configuration, accounts, ct);
            if (errors.Count > 0) return Results.BadRequest(new { errors });

            await webSettings.MergeSectionAsync("InternetExposed", dto, ct);
            return Results.Ok(new { saved = true, restartRequired = true });
        });

        // "send test email" under EMAIL: sends with what is saved and says what the mail server
        // answered. Ignores Enabled, so the account can be proved before it is switched on.
        app.MapPost("/api/notifications/test/email", async (AppSettingsFile appSettings, CancellationToken ct) =>
        {
            var email = await appSettings.GetSectionAsync<EmailOptions>(EmailOptions.SectionName, ct);
            if (email is null || string.IsNullOrWhiteSpace(email.ToAddress))
                return Results.BadRequest(new { error = "Fill in and save the EMAIL section first - there is no To Address yet." });
            if (SmtpMailer.ValidateDeliverable(email) is { } problem)
                return Results.BadRequest(new { error = problem });
            try
            {
                using var message = new MailMessage
                {
                    From = new MailAddress(SmtpMailer.FromAddressFor(email), email.FromName),
                    Subject = "ReelHouse test email",
                    IsBodyHtml = false,
                    Body = "This is a test message from your ReelHouse server. If you are reading it, email is set up correctly."
                };
                message.To.Add(email.ToAddress);
                await SmtpMailer.SendAsync(email, message, ct);
                return Results.Ok(new { sent = true, message = $"Sent to {email.ToAddress}." });
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return Results.Json(new { error = "The mail server refused: " + ex.Message }, statusCode: StatusCodes.Status502BadGateway);
            }
        }).RequireAuthorization("AdminOnly");

        // Restart-required settings (the listen address, Internet Exposed Mode) save fine remotely
        // but only apply on restart. There is one process here, so whatever service name a client
        // sends, this is the one that restarts. Refused when nothing would bring it back up - see
        // RestartSupport.
        app.MapPost("/api/system/restart", (
            RestartRequest? request, IConfiguration configuration, IHostApplicationLifetime lifetime, ILogger<RestartRequest> logger) =>
        {
            if (!RestartSupport.IsSupervised(configuration))
            {
                return Results.Conflict(new
                {
                    error = "ReelHouse isn't running under a supervisor that would restart it, so exiting would just take it down. " +
                            "Run it as a service (the shipped systemd unit restarts automatically), or set Restart:ForceAllowed to true " +
                            "if a supervisor this can't detect (Docker, launchd) is in charge."
                });
            }

            logger.LogWarning("Restart requested - shutting down for the supervisor to bring us back.");
            RestartSupport.StopSoon(lifetime);
            return Results.Accepted(value: new { restarting = true });
        }).RequireAuthorization("AdminOnly");
    }

    internal static async Task<List<string>> ValidateInternetExposedAsync(
        InternetExposedSettingsDto dto, IConfiguration configuration, IAccountStore accounts, CancellationToken ct)
    {
        var errors = ValidateDataAnnotations(dto);
        if (!dto.Enabled) return errors;

        var httpsSettings = HttpsSettings.FromConfiguration(configuration);
        if (!httpsSettings.CanEnable(out var httpsReason))
        {
            errors.Add(httpsReason
                ?? "Internet Exposed Mode requires a local HTTPS certificate to be configured first (HTTPS is on by default; check the Https section of appsettings.json).");
        }
        else if (dto.Port == httpsSettings.Port)
        {
            errors.Add($"Internet Exposed port {dto.Port} must be different from the HTTPS port.");
        }

        if (!await accounts.AnyAccountsExistAsync(ct))
            errors.Add("Create an admin account before enabling Internet Exposed Mode - otherwise the port would require login with no way to sign in.");
        return errors;
    }

    public static async Task<SettingsSnapshot> BuildSnapshotAsync(AppSettingsFile settings, CancellationToken cancellationToken) => new(
        await settings.GetSectionAsync<EmailSettingsDto>("Email", cancellationToken) ?? new() { SmtpHost = "smtp.gmail.com", SmtpPort = 587, FromName = "ReelHouse" },
        await settings.GetSectionAsync<LoginAlertSettingsDto>("LoginAlerts", cancellationToken) ?? new(),
        await ReadLoggingAsync(settings, cancellationToken) ?? new(),
        await ReadServerAsync(settings, cancellationToken) ?? new() { Urls = $"http://0.0.0.0:{HttpsSettings.DefaultHttpPort}" },
        await settings.GetSectionAsync<MediaSettingsDto>(MediaSettingsDto.SectionName, cancellationToken) ?? new(),
        await settings.GetSectionAsync<MediaDownloadsSettingsDto>(MediaDownloadsSettingsDto.SectionName, cancellationToken) ?? new(),
        await settings.GetSectionAsync<MusicSettingsDto>(MusicSettingsDto.SectionName, cancellationToken) ?? new(),
        await settings.GetSectionAsync<PodcastSettingsDto>(PodcastSettingsDto.SectionName, cancellationToken) ?? new(),
        await settings.GetSectionAsync<PushNotificationSettingsDto>(PushNotificationSettingsDto.SectionName, cancellationToken) ?? new());

    private static readonly string[] LogLevelNames =
        ["Trace", "Debug", "Information", "Warning", "Error", "Critical", "None"];

    // The two named categories are the ones the shipped appsettings.json carries; anything else
    // in LogLevel (a category someone added by hand for targeted debugging) is read back and
    // written out untouched rather than being clobbered by the save.
    private static async Task<LoggingSettingsDto?> ReadLoggingAsync(AppSettingsFile settings, CancellationToken cancellationToken)
    {
        var logging = await settings.GetSectionAsync<JsonObject>("Logging", cancellationToken);
        if (logging?["LogLevel"] is not JsonObject levels) return null;
        return new LoggingSettingsDto
        {
            Default = levels["Default"]?.GetValue<string>() ?? "Information",
            MicrosoftAspNetCore = levels["Microsoft.AspNetCore"]?.GetValue<string>() ?? "Warning"
        };
    }

    private static async Task WriteLoggingAsync(LoggingSettingsDto dto, AppSettingsFile settings, CancellationToken cancellationToken)
    {
        var logging = await settings.GetSectionAsync<JsonObject>("Logging", cancellationToken) ?? new JsonObject();
        if (logging["LogLevel"] is not JsonObject levels)
        {
            levels = new JsonObject();
            logging["LogLevel"] = levels;
        }
        levels["Default"] = dto.Default;
        levels["Microsoft.AspNetCore"] = dto.MicrosoftAspNetCore;
        await settings.ReplaceSectionAsync("Logging", logging, cancellationToken);
    }

    private static async Task<ServerSettingsDto?> ReadServerAsync(AppSettingsFile settings, CancellationToken cancellationToken)
    {
        var urls = await settings.GetSectionAsync<string>("Urls", cancellationToken);
        return string.IsNullOrWhiteSpace(urls) ? null : new ServerSettingsDto { Urls = urls };
    }

    private static async Task<IResult> SaveSectionAsync<T>(
        T dto,
        AppSettingsFile settings,
        string sectionName,
        CancellationToken cancellationToken,
        Action<List<string>>? extraValidation = null)
        where T : notnull
    {
        // Secret fields arriving as the literal mask mean "unchanged" - swapped back to the
        // stored value first, so validation (and the extraValidation closures reading dto
        // fields) judge the real value rather than eight mask characters.
        await SettingsSecrets.UnmaskAsync(dto, sectionName, settings, cancellationToken);

        var errors = ValidateDataAnnotations(dto);
        extraValidation?.Invoke(errors);
        if (errors.Count > 0) return Results.BadRequest(new { errors });

        await settings.MergeSectionAsync(sectionName, dto, cancellationToken);
        return Results.Ok(new { saved = true });
    }

    private static List<string> ValidateDataAnnotations<T>(T instance) where T : notnull
    {
        var context = new ValidationContext(instance);
        var results = new List<ValidationResult>();
        Validator.TryValidateObject(instance, context, results, validateAllProperties: true);
        return results.Select(r => r.ErrorMessage ?? "Invalid value.").ToList();
    }
}
