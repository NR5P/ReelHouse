using System.Globalization;

namespace ReelHouse;

public sealed record AudioBriefingResult(string Greeting, IReadOnlyList<string> Speech, IReadOnlyList<AudioEntry> Episodes)
{
    // Everything spoken, as one announcement: what a speaker says before the episodes start.
    public string SpokenText => string.Join(" ", new[] { Greeting }.Concat(Speech));
}

// The Morning Briefing: a hello, today's date, then the newest episode of each show the person
// put in the briefing. Plain sentences, written to be read aloud by a phone's or a TV's speech
// voice.
public sealed class AudioBriefingBuilder(
    IAccountStore accounts,
    IPodcastAudioSource podcasts,
    TimeProvider clock,
    ILogger<AudioBriefingBuilder> logger)
{
    public const int MaxEpisodes = 5;

    // The server's own clock zone: it is the household's, the same one wake-up alarms use.
    public TimeZoneInfo TimeZone { get; init; } = TimeZoneInfo.Local;

    public async Task<AudioBriefingResult> BuildAsync(string userKey, CancellationToken cancellationToken)
    {
        var now = TimeZoneInfo.ConvertTime(clock.GetUtcNow(), TimeZone);
        var name = await DisplayNameAsync(userKey, cancellationToken);
        var greeting = (now.Hour switch { < 12 => "Good morning", < 17 => "Good afternoon", _ => "Good evening" })
            + (name is null ? "." : $", {name}.");

        var speech = new List<string> { $"It's {now:dddd}, {now:MMMM} {Ordinal(now.Day)}." };

        IReadOnlyList<AudioEntry> episodes = [];
        try
        {
            if (await podcasts.EnabledAsync(cancellationToken))
                episodes = await podcasts.BriefingEpisodesAsync(userKey, MaxEpisodes, cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogWarning(ex, "The briefing could not read the podcasts");
        }
        if (episodes.Count > 0)
            speech.Add(episodes.Count == 1 ? "Here's your news." : $"Here are {episodes.Count} new episodes.");
        else
            speech.Add("Have a great day.");

        return new AudioBriefingResult(greeting, speech, episodes);
    }

    private async Task<string?> DisplayNameAsync(string userKey, CancellationToken cancellationToken)
    {
        if (userKey.Length == 0) return null;
        var account = await accounts.GetByUsernameAsync(userKey, cancellationToken);
        var name = string.IsNullOrWhiteSpace(account?.DisplayName) ? account?.Username : account.DisplayName;
        if (string.IsNullOrWhiteSpace(name)) return null;
        // "Morgan Reed" -> "Morgan": a briefing says hello the way a person would.
        var first = name.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries)[0];
        return char.ToUpper(first[0], CultureInfo.InvariantCulture) + first[1..];
    }

    private static string Ordinal(int day) => day + (day % 100 is 11 or 12 or 13 ? "th" : (day % 10) switch { 1 => "st", 2 => "nd", 3 => "rd", _ => "th" });
}
