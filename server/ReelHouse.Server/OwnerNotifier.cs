using System.Net.Mail;

namespace ReelHouse;

// A plain message to the owner, by email, for things that are about the system rather than
// about something to watch - the download VPN's account running out is the first. Nothing goes
// out on an install with no mail account filled in; the caller logs regardless. Deliberately not
// gated on Email:Enabled: the account only has to be configured.
public interface IOwnerNotifier
{
    Task<bool> SendAsync(string subject, string text, CancellationToken cancellationToken);
}

public sealed class OwnerNotifier(
    AppSettingsFile settings,
    ILogger<OwnerNotifier> logger,
    IPushNotifier? push = null) : IOwnerNotifier
{
    // True when at least one channel accepted the message. Push goes to the admins' phones when
    // PUSH NOTIFICATIONS -> Server Problems is on.
    public async Task<bool> SendAsync(string subject, string text, CancellationToken cancellationToken)
    {
        var sent = false;
        sent |= await TrySendEmailAsync(subject, text, cancellationToken);
        if (push is not null)
            sent |= (await push.NotifyAdminsAsync(PushCategory.ServerAlerts, new PushMessage(subject, text, PushTypes.Server), cancellationToken)).Delivered > 0;
        return sent;
    }

    private async Task<bool> TrySendEmailAsync(string subject, string text, CancellationToken cancellationToken)
    {
        var email = await settings.GetSectionAsync<EmailOptions>("Email", cancellationToken);
        if (email is null || string.IsNullOrWhiteSpace(email.Username) ||
            string.IsNullOrWhiteSpace(email.AppPassword) || string.IsNullOrWhiteSpace(email.ToAddress))
            return false;

        try
        {
            using var message = new MailMessage
            {
                From = new MailAddress(SmtpMailer.FromAddressFor(email), email.FromName),
                Subject = subject,
                IsBodyHtml = false,
                Body = text
            };
            message.To.Add(email.ToAddress);
            await SmtpMailer.SendAsync(email, message, cancellationToken);
            return true;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Failed to email the owner: {Subject}", subject);
            return false;
        }
    }
}
