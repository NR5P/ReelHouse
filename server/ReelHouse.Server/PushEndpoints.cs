namespace ReelHouse;

// What the apps call to sign a phone up for notifications, and the test button. Every route needs
// a signed-in person (or login turned off): a device is registered to whoever registers it, and
// that is who it then gets notifications for.
public sealed record RegisterPushDeviceRequest(string Platform, string Token, string? DeviceName, string? AppVariant = null, bool? ApnsSandbox = null);
public sealed record UnregisterPushDeviceRequest(string Platform, string Token);

public static class PushEndpoints
{
    public static void MapPushEndpoints(this WebApplication app)
    {
        var push = app.MapGroup("/api/push").RequireAuthorization();

        // What the apps' Settings screens show: is it on, can this phone's kind be reached, and
        // how many of this person's devices are signed up.
        push.MapGet("/status", async (HttpContext context, PushNotifier notifier, PushDeviceStore devices, CancellationToken ct) =>
        {
            var options = await notifier.ReadSettingsAsync(ct);
            var dataRoot = notifier.DataRoot;
            var user = MediaEndpoints.UserKey(context);
            var mine = (await devices.GetAllAsync(ct)).Count(d => user.Length == 0 || d.Username == user);
            var routes = await notifier.RoutesAsync(options, ct);
            var problems = PushCredentials.Problems(options, dataRoot);
            if (routes.Apple == PushRoute.None || routes.Android == PushRoute.None)
                problems.Add(!routes.Licensed
                    ? "No ReelHouse license is installed, so the ReelHouse push service can't be used. An admin installs one under Settings -> LICENSE (or fills in your own Apple/Firebase keys)."
                    : !options.RelayEnabled
                        ? "The ReelHouse push service is switched off (Settings -> PUSH NOTIFICATIONS -> Use ReelHouse Push Service)."
                        : "The push service address in Settings -> PUSH NOTIFICATIONS isn't a valid web address.");
            return Results.Ok(new
            {
                enabled = options.Enabled,
                // "Configured" means this server can reach that kind of phone - with its own keys
                // or through the relay. The apps only need the yes/no.
                appleConfigured = routes.Apple != PushRoute.None,
                androidConfigured = routes.Android != PushRoute.None,
                appleRoute = routes.Apple.ToString().ToLowerInvariant(),
                androidRoute = routes.Android.ToString().ToLowerInvariant(),
                licensed = routes.Licensed,
                myDevices = mine,
                newEpisodes = options.NewEpisodes,
                downloads = options.Downloads,
                loginAlerts = options.LoginAlerts,
                serverAlerts = options.ServerAlerts,
                wakeAlarms = options.WakeAlarms,
                problems
            });
        });

        push.MapPost("/devices", async (RegisterPushDeviceRequest request, HttpContext context, PushDeviceStore devices, PushNotifier notifier, CancellationToken ct) =>
        {
            var errors = Validate(request.Platform, request.Token, request.DeviceName, request.AppVariant);
            if (errors.Count > 0) return Results.BadRequest(new { errors });
            var platform = PushPlatforms.Normalize(request.Platform);
            var variant = string.IsNullOrWhiteSpace(request.AppVariant)
                ? platform == PushPlatforms.Android ? "android" : "ios"
                : request.AppVariant.Trim().ToLowerInvariant();
            var device = await devices.UpsertAsync(platform, request.Token, request.DeviceName?.Trim(), variant,
                request.ApnsSandbox ?? false, MediaEndpoints.UserKey(context), ct);
            _ = notifier.ForwardRegistrationAsync(device, remove: false);
            return Results.Ok(new { device.Id, device.Platform, device.DeviceName, device.AppVariant, device.UpdatedAt });
        });

        push.MapPost("/devices/unregister", async (UnregisterPushDeviceRequest request, PushDeviceStore devices, PushNotifier notifier, CancellationToken ct) =>
        {
            var errors = Validate(request.Platform, request.Token, null, null);
            if (errors.Count > 0) return Results.BadRequest(new { errors });
            var existing = (await devices.GetAllAsync(ct)).FirstOrDefault(d =>
                d.Platform == PushPlatforms.Normalize(request.Platform) && d.Token == request.Token.Trim());
            await devices.RemoveAsync(request.Platform, request.Token, ct);
            if (existing is not null) _ = notifier.ForwardRegistrationAsync(existing, remove: true);
            return Results.Ok(new { success = true });
        });

        // Sends a test to the caller's own devices. Works with the Enabled switch still off, so
        // the keys can be checked before turning everything on; it still needs the keys.
        push.MapPost("/test", async (HttpContext context, PushNotifier notifier, CancellationToken ct) =>
        {
            var options = await notifier.ReadSettingsAsync(ct);
            var routes = await notifier.RoutesAsync(options, ct);
            if (routes.Apple == PushRoute.None && routes.Android == PushRoute.None)
                return Results.BadRequest(new { error = routes.Licensed
                    ? "Push can't reach any phone: the ReelHouse push service is switched off and no Apple/Firebase keys are filled in (Settings -> PUSH NOTIFICATIONS)."
                    : "Push isn't set up on the server yet: an admin installs the ReelHouse license under Settings -> LICENSE (or fills in their own Apple/Firebase keys under PUSH NOTIFICATIONS). See docs/PUSH.md." });

            var user = MediaEndpoints.UserKey(context);
            var report = await notifier.DeliverAsync(options, PushMessage.Test(), d => user.Length == 0 || d.Username == user, ct);
            if (report.Attempted == 0)
                return Results.BadRequest(new { error = "None of your devices are signed up yet. Open the ReelHouse app on your phone, sign in and allow notifications, then try again." });
            var message = report.Delivered == report.Attempted
                ? $"Sent to {report.Delivered} device{(report.Delivered == 1 ? "" : "s")}."
                : $"Sent to {report.Delivered} of {report.Attempted} devices - the server log says why the others failed.";
            if (!options.Enabled) message += " Push is still switched off, so nothing else will be sent until an admin turns on Enabled.";
            return Results.Ok(new { report.Attempted, report.Delivered, report.Failed, report.Removed, message });
        });
    }

    private static List<string> Validate(string? platform, string? token, string? deviceName, string? appVariant)
    {
        var errors = new List<string>();
        if (!PushPlatforms.IsSupported(platform)) errors.Add("Platform must be 'apple' or 'android'.");
        if (string.IsNullOrWhiteSpace(token)) errors.Add("A push token is required.");
        else if (token.Length > 4096) errors.Add("The push token is too long.");
        if (deviceName?.Length > 120) errors.Add("The device name is too long.");
        if (!string.IsNullOrWhiteSpace(appVariant) && appVariant.Trim().ToLowerInvariant() is not ("ios" or "tvos" or "android"))
            errors.Add("AppVariant must be 'ios', 'tvos' or 'android'.");
        return errors;
    }
}
