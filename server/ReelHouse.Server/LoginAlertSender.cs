using System.Collections.Concurrent;
using System.Net.Mail;

namespace ReelHouse;

public interface ILoginAlertSender
{
    Task NotifyInvalidLoginAsync(string attemptedUsername, string ip, string via, int failuresInWindow, CancellationToken cancellationToken);
}

// Emails the owner when someone gets a sign-in wrong, through the EMAIL account in Settings.
public sealed class LoginAlertSender(
    AppSettingsFile settings,
    ILogger<LoginAlertSender> logger,
    IPushNotifier? push = null) : ILoginAlertSender
{
    // Keyed by IP only, not IP+username - a brute-force burst tries many usernames from one
    // address, and that whole burst should still cost one alert, not one per guess.
    private readonly ConcurrentDictionary<string, DateTimeOffset> _lastSent = new();

    public async Task NotifyInvalidLoginAsync(string attemptedUsername, string ip, string via, int failuresInWindow, CancellationToken cancellationToken)
    {
        // Email follows LOGIN ALERTS -> Enabled; the push has its own switch under PUSH
        // NOTIFICATIONS. The cooldown is shared, so one burst is one alert on each.
        var options = await settings.GetSectionAsync<LoginAlertOptions>("LoginAlerts", cancellationToken) ?? new LoginAlertOptions();
        var pushOptions = await settings.GetSectionAsync<PushNotificationSettingsDto>(PushNotificationSettingsDto.SectionName, cancellationToken) ?? new();
        var pushWanted = push is not null && PushNotifier.Allows(pushOptions, PushCategory.LoginAlerts);
        if (!options.Enabled && !pushWanted) return;

        var now = DateTimeOffset.UtcNow;
        if (_lastSent.TryGetValue(ip, out var last) && now - last < TimeSpan.FromMinutes(options.CooldownMinutes))
            return;

        var report = new LoginAlertReport(attemptedUsername, ip, via, failuresInWindow, now);

        var sent = false;
        if (options.Enabled) sent |= await TrySendEmailAsync(report, cancellationToken);
        if (pushWanted)
            sent |= (await push!.NotifyAdminsAsync(PushCategory.LoginAlerts, LoginAlertNotification.BuildPush(report), cancellationToken)).Delivered > 0;

        // Only starts the cooldown once something was actually delivered - an alert that
        // couldn't be sent (misconfigured SMTP) shouldn't also suppress
        // the next attempt's chance to try again.
        if (sent) _lastSent[ip] = now;
    }

    // Deliberately doesn't require Email:Enabled - only the account to be filled in; gated by
    // LoginAlerts:Enabled above.
    private async Task<bool> TrySendEmailAsync(LoginAlertReport report, CancellationToken cancellationToken)
    {
        var email = await settings.GetSectionAsync<EmailOptions>("Email", cancellationToken);
        if (email is null || string.IsNullOrWhiteSpace(email.Username) ||
            string.IsNullOrWhiteSpace(email.AppPassword) || string.IsNullOrWhiteSpace(email.ToAddress))
        {
            logger.LogDebug("Skipping the invalid-login email - Email isn't enabled/configured");
            return false;
        }

        try
        {
            using var message = LoginAlertNotification.BuildEmail(email, report);
            await SmtpMailer.SendAsync(email, message, cancellationToken);
            logger.LogInformation("Sent an invalid-login email for {Ip}", report.Ip);
            return true;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Failed to send the invalid-login email");
            return false;
        }
    }
}

public sealed record LoginAlertReport(string AttemptedUsername, string Ip, string Via, int FailuresInWindow, DateTimeOffset OccurredAt);

public static class LoginAlertNotification
{
    public static PushMessage BuildPush(LoginAlertReport report) => new(
        "Failed ReelHouse sign-in",
        report.FailuresInWindow > 1
            ? $"{report.FailuresInWindow} wrong passwords for \"{report.AttemptedUsername}\" from {report.Ip}."
            : $"Wrong password for \"{report.AttemptedUsername}\" from {report.Ip}.",
        PushTypes.Login);

    public static MailMessage BuildEmail(EmailOptions email, LoginAlertReport report)
    {
        var fromAddress = SmtpMailer.FromAddressFor(email);

        var message = new MailMessage
        {
            From = new MailAddress(fromAddress, email.FromName),
            Subject = "Invalid login attempt on ReelHouse",
            IsBodyHtml = false,
            Body = $"""
                Someone entered an incorrect password for ReelHouse.

                Attempted username: {report.AttemptedUsername}
                Source address:     {report.Ip} ({report.Via})
                Time:                {report.OccurredAt.ToLocalTime():yyyy-MM-dd HH:mm:ss zzz}
                Failed attempts from this address in the current window: {report.FailuresInWindow}

                Further alerts from this same address are suppressed for a while so repeated
                guesses don't flood your inbox - check the server log for the full history.
                """
        };

        message.To.Add(email.ToAddress);
        return message;
    }
}
