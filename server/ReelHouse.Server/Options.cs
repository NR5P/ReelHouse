using System.ComponentModel.DataAnnotations;

namespace ReelHouse;

// The mail account messages to the owner go out through: a failed sign-in (LoginAlertSender) and
// things about the system itself, like the VPN account running out (OwnerNotifier).
public sealed class EmailOptions
{
    public const string SectionName = "Email";

    public bool Enabled { get; init; }

    [Required]
    public string SmtpHost { get; init; } = "smtp.gmail.com";

    // 587 (STARTTLS) is what most providers document first, but 465 (TLS from the first byte) and
    // 25/2525 for a relay on the LAN all work - see SmtpMailer.SecurityFor.
    [Range(1, 65535)]
    public int SmtpPort { get; init; } = 587;

    public bool EnableSsl { get; init; } = true;

    // Blank means the server wants no login, which is normal for a relay on your own network.
    // It does not have to be an email address: SES uses an access key, SendGrid the literal word
    // "apikey". Whenever it isn't one, FromAddress has to be filled in instead.
    public string Username { get; init; } = string.Empty;
    public string AppPassword { get; init; } = string.Empty;
    public string FromAddress { get; init; } = string.Empty;
    public string FromName { get; init; } = "ReelHouse";
    public string ToAddress { get; init; } = string.Empty;

    [Range(5, 300)]
    public int TimeoutSeconds { get; init; } = 30;
}

public sealed class LoginAlertOptions
{
    public const string SectionName = "LoginAlerts";

    // Off by default: nothing is sent anywhere until explicitly turned on. Sending still depends
    // on the Email account being filled in.
    public bool Enabled { get; init; }

    // One alert per source IP per window, no matter how many usernames are tried against it.
    [Range(1, 1440)]
    public int CooldownMinutes { get; init; } = 15;
}
