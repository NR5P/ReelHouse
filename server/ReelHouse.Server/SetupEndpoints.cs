namespace ReelHouse;

public sealed class SetupStatusDto
{
    public bool Completed { get; set; }
}

// Powers the first-run welcome: whether it should show at all, and marking it done (or showing
// it again).
public static class SetupEndpoints
{
    public static void MapSetupEndpoints(this WebApplication app)
    {
        var setup = app.MapGroup("/api/setup").RequireAuthorization("AdminOnly");

        setup.MapGet("/status", async (AppSettingsFile settings, CancellationToken ct) =>
        {
            var status = await settings.GetSectionAsync<SetupStatusDto>("Setup", ct);
            return Results.Ok(new { completed = status?.Completed ?? false });
        });

        setup.MapPost("/complete", async (AppSettingsFile settings, CancellationToken ct) =>
        {
            await settings.MergeSectionAsync("Setup", new SetupStatusDto { Completed = true }, ct);
            return Results.Ok(new { completed = true });
        });

        setup.MapPost("/reset", async (AppSettingsFile settings, CancellationToken ct) =>
        {
            await settings.MergeSectionAsync("Setup", new SetupStatusDto { Completed = false }, ct);
            return Results.Ok(new { completed = false });
        });
    }
}
