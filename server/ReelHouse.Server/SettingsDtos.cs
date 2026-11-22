using System.ComponentModel.DataAnnotations;

namespace ReelHouse;

public sealed class EmailSettingsDto
{
    public bool Enabled { get; set; }

    [Required]
    public string SmtpHost { get; set; } = string.Empty;

    [Range(1, 65535)]
    public int SmtpPort { get; set; }

    public bool EnableSsl { get; set; } = true;
    public string Username { get; set; } = string.Empty;
    public string AppPassword { get; set; } = string.Empty;
    public string FromAddress { get; set; } = string.Empty;
    public string FromName { get; set; } = string.Empty;
    public string ToAddress { get; set; } = string.Empty;

    // One of the few TimeoutSeconds the note at the top of this file doesn't exclude: nothing
    // holds an SMTP connection open between sends, so it's read fresh on the next email.
    [Range(5, 300)]
    public int TimeoutSeconds { get; set; } = 30;

    // Lets the saved form be judged by SmtpMailer.ValidateDeliverable, the same code that decides
    // whether the server will boot with this Email section - see SettingsEndpoints' /email PUT.
    public EmailOptions ToOptions() => new()
    {
        Enabled = Enabled,
        SmtpHost = SmtpHost,
        SmtpPort = SmtpPort,
        EnableSsl = EnableSsl,
        Username = Username,
        AppPassword = AppPassword,
        FromAddress = FromAddress,
        FromName = FromName,
        ToAddress = ToAddress,
        TimeoutSeconds = TimeoutSeconds
    };
}

// Backing DTO for the Settings UI's "Internet Exposed Mode" toggle - persisted separately from
// the rest of SettingsSnapshot (see SettingsEndpoints.MapInternetExposedEndpoints) because it
// lives in this project's own appsettings.json (it configures this project's own Kestrel
// binding, same category as HttpsSettings), not the main app's shared settings file.
public sealed class InternetExposedSettingsDto
{
    public bool Enabled { get; set; }

    [Range(1, 65535)]
    public int Port { get; set; } = InternetExposedSettings.DefaultPort;
}

public sealed class LoginAlertSettingsDto
{
    public bool Enabled { get; set; }

    [Range(1, 1440)]
    public int CooldownMinutes { get; set; } = 15;
}

// Flat on purpose, even though the file shape is Logging.LogLevel.{Default,Microsoft.AspNetCore}:
// "Microsoft.AspNetCore" contains dots, so exposing the real nesting would make the flattened
// field paths the schema uses ambiguous. The endpoint maps between this and the real shape - see
// the /logging handler in SettingsEndpoints, which also preserves any extra LogLevel categories
// someone added to the file by hand.
public sealed class LoggingSettingsDto
{
    public string Default { get; set; } = "Information";
    public string MicrosoftAspNetCore { get; set; } = "Warning";
}

// "Urls" is a bare string at the root of appsettings.json, not a section - the one setting in
// the schema whose save handler writes a scalar. Restart-required: Kestrel binds it once at
// startup.
public sealed class ServerSettingsDto
{
    [Required]
    public string Urls { get; set; } = string.Empty;
}
