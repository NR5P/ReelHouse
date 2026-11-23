using System.Collections.Concurrent;
using System.Text.RegularExpressions;

namespace ReelHouse;

// Changing an album's cover by hand (admin only, docs/MUSIC_AND_PODCASTS.md "Album covers"): the
// covers on offer from the Cover Art Archive and Apple, picking one of them, uploading a picture,
// and going back to automatic. A cover set here is pinned (source chosen or custom): it wins over
// the embedded picture and folder art, and no scan replaces or rechecks it.
//
// The server only ever downloads a cover it offered itself: the candidate list for an album is
// kept here for half an hour (and worked out again if it has gone), and a pick names a candidate
// by id, never a URL. Downloads are limited to the hosts in MusicArtHosts.
public sealed partial class MusicCoverService(
    IMusicStore store,
    MusicScanner scanner,
    AppSettingsFile settings,
    MusicArtCache art,
    MusicCoverArtClient coverArt,
    MusicITunesArtClient itunes,
    MusicArtDownloader downloader,
    ILogger<MusicCoverService> logger)
{
    private static readonly TimeSpan OfferLifetime = TimeSpan.FromMinutes(30);
    private readonly ConcurrentDictionary<Guid, Offer> _offers = new();

    public sealed record Candidate(string Id, string Source, Uri Thumb, Uri Full, string Label);

    public sealed record CandidateList(IReadOnlyList<Candidate> Candidates, string? Note);

    private sealed record Offer(DateTimeOffset Expires, IReadOnlyList<Candidate> Candidates);

    // MARK: - Candidates

    // The covers the Cover Art Archive (every picture of the album's release and release group,
    // fronts first) and Apple's iTunes search (albums by that title or artist, the close matches
    // first) have for the album. Either one failing is a note, not an error: the other's covers
    // are still offered.
    public async Task<CandidateList> CandidatesAsync(MusicAlbumInfo album, CancellationToken cancellationToken)
    {
        var options = await settings.GetSectionAsync<MusicSettingsDto>(MusicSettingsDto.SectionName, cancellationToken) ?? new();
        if (!options.FetchArtworkOnline)
        {
            Remember(album.Id, []);
            return new([], "Looking up covers online is turned off in the Music settings (Find Missing Album Covers), so only an uploaded picture can be used.");
        }

        var candidates = new List<Candidate>();
        var notes = new List<string>();
        var known = album.Title != MusicText.UnknownAlbum;

        try
        {
            var release = album.Tracks.Select(t => t.MusicBrainzReleaseId).FirstOrDefault(id => !string.IsNullOrWhiteSpace(id));
            var group = album.Tracks.Select(t => t.MusicBrainzReleaseGroupId).FirstOrDefault(id => !string.IsNullOrWhiteSpace(id));
            if (group is null && known) group = await coverArt.FindReleaseGroupAsync(album.Artist, album.Title, cancellationToken);
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var (kind, mbid) in new[] { ("release", release), ("release-group", group) })
            {
                if (mbid is null) continue;
                foreach (var image in await coverArt.ListImagesAsync(kind, mbid, cancellationToken))
                    if (seen.Add(image.Id))
                        candidates.Add(new Candidate($"caa-{image.Id}", MusicArtSources.CoverArtArchive, image.Thumb, image.Full,
                            image.Types.Length > 0 ? image.Types : image.Front ? "Front" : "Picture"));
            }
        }
        catch (Exception ex) when (IsNetwork(ex, cancellationToken))
        {
            logger.LogInformation("Cover Art Archive candidates for {Album} failed: {Message}", album.Title, ex.Message);
            notes.Add("The Cover Art Archive couldn't be reached, so its covers aren't listed.");
        }

        if (known)
        {
            try
            {
                var results = await itunes.SearchAsync(album.Artist, album.Title, cancellationToken);
                var related = results
                    .Where(r => MusicITunesArtClient.ArtistMatches(album.Artist, r.Artist) || MusicITunesArtClient.TitleMatches(album.Title, r.Title))
                    .OrderByDescending(r => MusicITunesArtClient.ArtistMatches(album.Artist, r.Artist) && MusicITunesArtClient.TitleMatches(album.Title, r.Title));
                foreach (var result in related)
                {
                    var thumb = MusicArtHosts.Normalize(MusicITunesArtClient.Artwork(result.ArtworkUrl100, 300));
                    var full = MusicArtHosts.Normalize(MusicITunesArtClient.Artwork(result.ArtworkUrl100, 1200));
                    if (thumb is null || full is null) continue;
                    var label = string.Join(" · ", new[] { result.Title, result.Artist, result.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture) }
                        .Where(s => !string.IsNullOrWhiteSpace(s)));
                    candidates.Add(new Candidate($"itunes-{result.Id}", MusicArtSources.ITunes, thumb, full, label));
                }
            }
            catch (Exception ex) when (IsNetwork(ex, cancellationToken))
            {
                logger.LogInformation("iTunes candidates for {Album} failed: {Message}", album.Title, ex.Message);
                notes.Add("Apple's iTunes search couldn't be reached, so its covers aren't listed.");
            }
        }

        Remember(album.Id, candidates);
        var note = notes.Count > 0 ? string.Join(" ", notes)
            : candidates.Count == 0 ? "No covers were found online for this album. You can still upload a picture." : null;
        return new(candidates, note);
    }

    private void Remember(Guid albumId, IReadOnlyList<Candidate> candidates)
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var (id, offer) in _offers)
            if (offer.Expires < now) _offers.TryRemove(id, out _);
        _offers[albumId] = new Offer(now + OfferLifetime, candidates);
    }

    // The candidate with this id from the album's list: the one kept from CandidatesAsync, or a
    // freshly worked-out one if that has expired. Null when the album isn't offered it.
    private async Task<Candidate?> OfferedAsync(MusicAlbumInfo album, string candidateId, CancellationToken cancellationToken)
    {
        if (!CandidateId().IsMatch(candidateId)) return null;
        if (_offers.TryGetValue(album.Id, out var offer) && offer.Expires >= DateTimeOffset.UtcNow)
            return offer.Candidates.FirstOrDefault(c => c.Id == candidateId);
        return (await CandidatesAsync(album, cancellationToken)).Candidates.FirstOrDefault(c => c.Id == candidateId);
    }

    // MARK: - Setting a cover

    // Downloads the picked candidate and pins it (source chosen). Null when the album was never
    // offered that candidate. Throws MusicCoverException (not a usable picture, or gone) and
    // HttpRequestException (the network).
    public async Task<MusicArtRecord?> ChooseAsync(MusicAlbumInfo album, string candidateId, CancellationToken cancellationToken)
    {
        if (await OfferedAsync(album, candidateId, cancellationToken) is not { } candidate) return null;
        var data = await downloader.GetAsync(candidate.Full, cancellationToken)
                   ?? throw new MusicCoverException("That cover isn't there any more. Open the list again and pick another.");
        return await PinAsync(album, data, MusicArtSources.Chosen, cancellationToken);
    }

    // An uploaded picture (JPEG, PNG or WebP), pinned as source custom.
    public Task<MusicArtRecord> UploadAsync(MusicAlbumInfo album, byte[] data, CancellationToken cancellationToken) =>
        PinAsync(album, data, MusicArtSources.Custom, cancellationToken);

    private async Task<MusicArtRecord> PinAsync(MusicAlbumInfo album, byte[] data, string source, CancellationToken cancellationToken)
    {
        var key = MusicArtCache.AlbumKey(album.Id);
        var previous = (await store.GetArtAsync(cancellationToken)).GetValueOrDefault(key);
        var path = art.PinnedAlbumPath(album.Id);
        if (File.Exists(path)) art.ForgetSized(path, LocalMediaFileSystem.Instance);
        await MusicArtImages.SaveAsJpegAsync(data, path, cancellationToken);
        var record = new MusicArtRecord(key, path, source, DateTimeOffset.UtcNow);
        await store.SetArtAsync(record, cancellationToken);
        // The automatic cover this replaces is not needed any more, if the server made it (never
        // folder art beside the music). "Reset to automatic" looks it up again.
        if (previous?.Path is { } old && old != path && art.Owns(old)) Delete(old);
        logger.LogInformation("Album cover for {Album} set by hand ({Source})", album.Title, source);
        return record;
    }

    // Forgets the pinned cover and looks the album up again straight away, as a scan would. The
    // record that lookup saved, or null when an online lookup failed (the next scan tries again).
    public async Task<MusicArtRecord?> ResetAsync(MusicAlbumInfo album, CancellationToken cancellationToken)
    {
        var key = MusicArtCache.AlbumKey(album.Id);
        var previous = (await store.GetArtAsync(cancellationToken)).GetValueOrDefault(key);
        await store.DeleteArtAsync([key], includePinned: true, cancellationToken);
        Delete(art.PinnedAlbumPath(album.Id));
        if (previous?.Path is { } old && art.Owns(old)) Delete(old);
        return await scanner.LookUpAlbumArtAsync(album.Id, album.Tracks, cancellationToken);
    }

    private void Delete(string path)
    {
        if (!File.Exists(path)) return;
        art.ForgetSized(path, LocalMediaFileSystem.Instance);
        try { File.Delete(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { logger.LogDebug("Could not delete {Path}: {Message}", path, ex.Message); }
    }

    // MARK: - Find missing covers now

    // Makes every album with no cover due now and starts the artwork pass in the background.
    public async Task<(int Queued, bool Started)> RefreshMissingAsync(CancellationToken cancellationToken)
    {
        var queued = await scanner.QueueMissingArtAsync(cancellationToken);
        return (queued, queued > 0 && scanner.RequestArtworkPass());
    }

    public static bool IsNetwork(Exception ex, CancellationToken cancellationToken) =>
        ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException && !cancellationToken.IsCancellationRequested;

    [GeneratedRegex("^(?:caa|itunes)-[A-Za-z0-9]{1,40}$")]
    private static partial Regex CandidateId();
}
