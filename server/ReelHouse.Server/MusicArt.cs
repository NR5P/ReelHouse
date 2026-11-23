using System.Net;
using System.Text.Json;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Formats.Webp;
using SixLabors.ImageSharp.Processing;

namespace ReelHouse;

// Where an album's cover came from (MusicArtRecord.Source). The automatic ones, in the order the
// scanner tries them: embedded, folder, caa (Cover Art Archive), itunes (Apple's iTunes search),
// and none. The pinned ones an admin set by hand win over all of those, and no scan replaces or
// rechecks them: custom (an uploaded picture) and chosen (one picked from the candidates).
public static class MusicArtSources
{
    public const string Embedded = "embedded";
    public const string Folder = "folder";
    public const string CoverArtArchive = "caa";
    public const string ITunes = "itunes";
    public const string None = "none";
    public const string Custom = "custom";
    public const string Chosen = "chosen";

    public static bool IsPinned(string? source) => source is Custom or Chosen;
}

// Where album and artist art the server made itself lives: <data>/music-art/album-<id>.jpg for a
// picture taken out of a file or fetched online, album-<id>.pinned.jpg for one an admin set, and
// sized/ for the smaller copies the art endpoints hand out. Folder art (cover.jpg beside the
// tracks) is never copied here; it is served from where it is.
public sealed class MusicArtCache(string root)
{
    private readonly SizedArtCache _sized = new(Path.Combine(root, "sized"));

    public string Root { get; } = root;

    public string SizedRoot => _sized.Root;

    public string AlbumPath(Guid albumId, string extension) => Path.Combine(Root, $"album-{albumId:N}{extension}");

    // A cover an admin uploaded or picked. A name of its own, so nothing the scanner writes for
    // the album can land on it.
    public string PinnedAlbumPath(Guid albumId) => Path.Combine(Root, $"album-{albumId:N}.pinned.jpg");

    public static string AlbumKey(Guid albumId) => $"album:{albumId:N}";

    public static string ArtistKey(Guid artistId) => $"artist:{artistId:N}";

    public static int Bucket(int size) => SizedArtCache.Bucket(size);

    // True for a file this cache made (and so may delete), false for folder art beside the music.
    public bool Owns(string? path) =>
        path is not null && !MediaNetworkPath.IsNetwork(path) && Path.IsPathRooted(path) && Path.GetFullPath(path).StartsWith(Path.GetFullPath(Root) + Path.DirectorySeparatorChar, StringComparison.Ordinal);

    // A copy of the cover no wider or taller than `size` (see SizedArtCache).
    public Task<string> SizedAsync(string original, IMediaFileSystem fs, int size, CancellationToken cancellationToken) =>
        _sized.SizedAsync(original, fs, size, cancellationToken);

    // Drops the sized copies of `original` as it is now, before it is replaced or deleted.
    public void ForgetSized(string original, IMediaFileSystem fs) => _sized.Forget(original, fs);
}

// Something about a cover the admin should be told in words: not a picture, too big, or a host
// the server won't fetch from.
public sealed class MusicCoverException(string message) : Exception(message);

// The only hosts the server downloads album covers from: the Cover Art Archive (whose images are
// kept at, and redirect to, archive.org) and Apple's artwork CDN. Every hop of a download is
// checked against this, redirects included, so a cover URL can never point the server somewhere
// else.
public static class MusicArtHosts
{
    public static bool IsAllowed(Uri uri) =>
        uri.IsAbsoluteUri && uri.Scheme == Uri.UriSchemeHttps && uri.IsDefaultPort && uri.UserInfo.Length == 0
        && (IsOrUnder(uri.Host, "coverartarchive.org") || IsOrUnder(uri.Host, "archive.org")
            || uri.Host.EndsWith(".mzstatic.com", StringComparison.OrdinalIgnoreCase));

    // The URL as https (the Cover Art Archive's JSON still says http://), or null when it is not
    // on an allowed host.
    public static Uri? Normalize(string? url)
    {
        if (string.IsNullOrWhiteSpace(url) || !Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme == Uri.UriSchemeHttp && uri.IsDefaultPort)
            uri = new UriBuilder(uri) { Scheme = Uri.UriSchemeHttps, Port = -1 }.Uri;
        return IsAllowed(uri) ? uri : null;
    }

    private static bool IsOrUnder(string host, string domain) =>
        host.Equals(domain, StringComparison.OrdinalIgnoreCase) || host.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase);
}

// Downloads a cover picture from an allowed host, following redirects by hand (the named client
// is registered with automatic redirects off) so each hop is checked, and never more than
// MaxBytes.
public sealed class MusicArtDownloader(IHttpClientFactory http)
{
    public const string HttpClientName = "MusicCoverDownload";
    public const long MaxBytes = 15 * 1024 * 1024;
    private const int MaxRedirects = 5;

    // The bytes at `url`, or null when it is not there (404). Throws MusicCoverException for a
    // host that isn't allowed or a file too big, HttpRequestException for the network.
    public async Task<byte[]?> GetAsync(Uri url, CancellationToken cancellationToken)
    {
        var client = http.CreateClient(HttpClientName);
        for (var hop = 0; hop <= MaxRedirects; hop++)
        {
            if (!MusicArtHosts.IsAllowed(url)) throw new MusicCoverException("ReelHouse only downloads covers from the Cover Art Archive and Apple.");
            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } location)
            {
                var next = location.IsAbsoluteUri ? location : new Uri(url, location);
                url = MusicArtHosts.Normalize(next.ToString())
                      ?? throw new MusicCoverException("The cover's address led somewhere ReelHouse doesn't download from.");
                continue;
            }
            if (response.StatusCode == HttpStatusCode.NotFound) return null;
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > MaxBytes) throw TooBig();
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            return await ReadCappedAsync(stream, MaxBytes, cancellationToken) ?? throw TooBig();
        }
        throw new HttpRequestException("The cover's address redirected too many times.");
    }

    public static MusicCoverException TooBig() => new($"That picture is bigger than {MaxBytes / (1024 * 1024)} MB.");

    // All of the stream, or null as soon as it passes `max` bytes.
    public static async Task<byte[]?> ReadCappedAsync(Stream stream, long max, CancellationToken cancellationToken)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        int read;
        while ((read = await stream.ReadAsync(chunk, cancellationToken)) > 0)
        {
            if (buffer.Length + read > max) return null;
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }
}

// A cover the server keeps for good: decoded (JPEG, PNG or WebP only, through
// SafeImageDecoding), turned the right way up, shrunk to MaxSide and written as a baseline JPEG.
// What the art endpoints serve is then always a plain JPEG whatever was uploaded.
public static class MusicArtImages
{
    public const int MaxSide = 1500;
    private const int MaxDecodedSide = 12000;
    public const string NotAPicture = "That file isn't a picture ReelHouse can use. Choose a JPEG, PNG or WebP image.";

    public static async Task SaveAsJpegAsync(byte[] data, string destination, CancellationToken cancellationToken)
    {
        Image image;
        try
        {
            // Read the size first: a tiny file can claim an enormous picture.
            var info = Image.Identify(SafeImageDecoding.Options, data);
            if (info.Width > MaxDecodedSide || info.Height > MaxDecodedSide || info.Width < 1 || info.Height < 1)
                throw new MusicCoverException("That picture is too large to use as a cover.");
            if (info.Metadata.DecodedImageFormat is not (JpegFormat or PngFormat or WebpFormat)) throw new MusicCoverException(NotAPicture);
            image = Image.Load(SafeImageDecoding.Options, data);
        }
        catch (Exception ex) when (ex is ImageFormatException or UnknownImageFormatException or InvalidImageContentException or NotSupportedException or ArgumentException)
        {
            throw new MusicCoverException(NotAPicture);
        }
        using (image)
        {
            image.Mutate(context =>
            {
                context.AutoOrient();
                if (image.Width > MaxSide || image.Height > MaxSide)
                    context.Resize(new ResizeOptions { Size = new Size(MaxSide, MaxSide), Mode = ResizeMode.Max });
            });
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            var temporary = $"{destination}.{Guid.NewGuid():N}.tmp";
            try
            {
                await image.SaveAsJpegAsync(temporary, new JpegEncoder { Quality = 90 }, cancellationToken);
                File.Move(temporary, destination, overwrite: true);
            }
            finally
            {
                try { File.Delete(temporary); } catch (IOException) { }
            }
        }
    }
}

// Album covers from the Cover Art Archive, found through MusicBrainz. MusicBrainz asks every
// client for a descriptive User-Agent and at most one request a second; both are kept here for
// every caller in the process. A release id in the file's tags skips the search entirely.
public sealed class MusicCoverArtClient(IHttpClientFactory http, ILogger<MusicCoverArtClient> logger)
{
    public const string HttpClientName = "MusicBrainz";
    private static readonly TimeSpan MusicBrainzSpacing = TimeSpan.FromSeconds(1.1);
    private readonly SemaphoreSlim _musicBrainzGate = new(1, 1);
    private DateTimeOffset _lastMusicBrainzRequest = DateTimeOffset.MinValue;

    // One picture of a release or release group in the archive: a small thumbnail to show, and
    // the large one to download if it is picked.
    public sealed record ArchiveImage(string Id, Uri Thumb, Uri Full, bool Front, string Types);

    // The release group's id on MusicBrainz for an album, or null when nothing matches well.
    public async Task<string?> FindReleaseGroupAsync(string artist, string album, CancellationToken cancellationToken)
    {
        // Without an edition or year tail ("Eagles (1972)" is the release group "Eagles").
        var title = MusicText.EditionlessTitle(album);
        var key = MusicText.EditionlessKey(album);
        var query = $"releasegroup:\"{Escape(title)}\"" + (MusicAlbumRules.IsVariousArtists(artist) ? "" : $" AND artist:\"{Escape(artist)}\"");
        using var document = await MusicBrainzAsync($"https://musicbrainz.org/ws/2/release-group/?query={Uri.EscapeDataString(query)}&fmt=json&limit=5", cancellationToken);
        if (document is null || !document.RootElement.TryGetProperty("release-groups", out var groups)) return null;
        foreach (var group in groups.EnumerateArray())
        {
            var score = group.TryGetProperty("score", out var s) && s.TryGetInt32(out var value) ? value : 0;
            var name = group.TryGetProperty("title", out var t) ? t.GetString() : null;
            if (score >= 90 && MusicText.EditionlessKey(name) == key && group.TryGetProperty("id", out var id))
                return id.GetString();
        }
        return null;
    }

    private async Task<JsonDocument?> MusicBrainzAsync(string url, CancellationToken cancellationToken)
    {
        await _musicBrainzGate.WaitAsync(cancellationToken);
        try
        {
            var wait = _lastMusicBrainzRequest + MusicBrainzSpacing - DateTimeOffset.UtcNow;
            if (wait > TimeSpan.Zero) await Task.Delay(wait, cancellationToken);
            _lastMusicBrainzRequest = DateTimeOffset.UtcNow;
            using var response = await http.CreateClient(HttpClientName).GetAsync(url, cancellationToken);
            if (response.StatusCode == HttpStatusCode.NotFound) return null;
            response.EnsureSuccessStatusCode();
            return await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
        }
        finally { _musicBrainzGate.Release(); }
    }

    // Downloads the front cover (500 px) of a release or release group into `destination`.
    // False when the archive has none.
    public async Task<bool> DownloadFrontAsync(string kind, string mbid, string destination, CancellationToken cancellationToken)
    {
        var url = $"https://coverartarchive.org/{kind}/{Uri.EscapeDataString(mbid)}/front-500";
        using var response = await http.CreateClient(HttpClientName).GetAsync(url, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound) return false;
        response.EnsureSuccessStatusCode();
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var temporary = destination + ".tmp";
        await using (var file = File.Create(temporary))
            await response.Content.CopyToAsync(file, cancellationToken);
        File.Move(temporary, destination, overwrite: true);
        logger.LogDebug("Cover Art Archive: saved {Url}", url);
        return true;
    }

    // Every picture the archive has for a release or release group (its JSON listing), front
    // covers first. Empty when it has none.
    public async Task<IReadOnlyList<ArchiveImage>> ListImagesAsync(string kind, string mbid, CancellationToken cancellationToken)
    {
        var url = $"https://coverartarchive.org/{kind}/{Uri.EscapeDataString(mbid)}";
        using var response = await http.CreateClient(HttpClientName).GetAsync(url, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound) return [];
        response.EnsureSuccessStatusCode();
        using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
        if (!document.RootElement.TryGetProperty("images", out var images) || images.ValueKind != JsonValueKind.Array) return [];
        var list = new List<ArchiveImage>();
        foreach (var image in images.EnumerateArray())
        {
            if (image.ValueKind != JsonValueKind.Object || !image.TryGetProperty("id", out var idElement)) continue;
            var id = idElement.ValueKind == JsonValueKind.String ? idElement.GetString() : idElement.GetRawText();
            if (string.IsNullOrWhiteSpace(id) || !id.All(char.IsAsciiLetterOrDigit)) continue;
            var thumbnails = image.TryGetProperty("thumbnails", out var t) && t.ValueKind == JsonValueKind.Object ? t : default;
            string? Thumbnail(params string[] names)
            {
                if (thumbnails.ValueKind != JsonValueKind.Object) return null;
                foreach (var name in names)
                    if (thumbnails.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String) return value.GetString();
                return null;
            }
            var original = image.TryGetProperty("image", out var o) && o.ValueKind == JsonValueKind.String ? o.GetString() : null;
            // The 1200 px thumbnail rather than the original, which can be a 50 MB scan.
            var full = MusicArtHosts.Normalize(Thumbnail("1200", "large", "500") ?? original);
            var thumb = MusicArtHosts.Normalize(Thumbnail("250", "small", "500")) ?? full;
            if (full is null || thumb is null) continue;
            var front = image.TryGetProperty("front", out var f) && f.ValueKind == JsonValueKind.True;
            var types = image.TryGetProperty("types", out var ty) && ty.ValueKind == JsonValueKind.Array
                ? string.Join(", ", ty.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()))
                : "";
            list.Add(new ArchiveImage(id, thumb, full, front, types));
        }
        return list.OrderByDescending(i => i.Front).ToList();
    }

    private static string Escape(string text) => text.Replace("\\", "\\\\").Replace("\"", "\\\"");
}

// Album covers from Apple's iTunes Search API (no key needed): the second online source, asked
// only when the Cover Art Archive has nothing. A result is used only when its album title and
// artist match the album here (editions like "(Remastered)" or "- Deluxe Edition" aside), and
// its 600x600 artwork is downloaded. Apple asks for restraint rather than naming a rate, so
// searches are kept at least Spacing apart (3 s) across the whole process, with a User-Agent
// that says what this is.
public sealed class MusicITunesArtClient(IHttpClientFactory http, MusicArtDownloader downloader, ILogger<MusicITunesArtClient> logger)
{
    public const string HttpClientName = "iTunesSearch";
    public static readonly TimeSpan DefaultSpacing = TimeSpan.FromSeconds(3);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private DateTimeOffset _lastRequest = DateTimeOffset.MinValue;

    public sealed record Album(long Id, string Title, string Artist, string? ArtworkUrl100, int? Year);

    // How far apart searches are kept. Tests shorten it.
    public TimeSpan Spacing { get; init; } = DefaultSpacing;

    // Searched for without an edition or year tail: an album filed as "Eagles (1972)" is "Eagles".
    public static string SearchUrl(string artist, string album)
    {
        var title = MusicText.EditionlessTitle(album);
        var term = MusicAlbumRules.IsVariousArtists(artist) ? title : $"{artist} {title}";
        return $"https://itunes.apple.com/search?term={Uri.EscapeDataString(term)}&entity=album&limit=10&media=music";
    }

    // Up to 10 albums Apple finds for the artist and title. Throws HttpRequestException (or a
    // timeout) when Apple can't be reached or says no: the caller retries later.
    public async Task<IReadOnlyList<Album>> SearchAsync(string artist, string album, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var wait = _lastRequest + Spacing - DateTimeOffset.UtcNow;
            if (wait > TimeSpan.Zero) await Task.Delay(wait, cancellationToken);
            _lastRequest = DateTimeOffset.UtcNow;
            using var response = await http.CreateClient(HttpClientName).GetAsync(SearchUrl(artist, album), cancellationToken);
            response.EnsureSuccessStatusCode();
            using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken), cancellationToken: cancellationToken);
            var list = new List<Album>();
            if (!document.RootElement.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array) return list;
            foreach (var result in results.EnumerateArray())
            {
                if (result.ValueKind != JsonValueKind.Object) continue;
                string? Text(string name) => result.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                if (!result.TryGetProperty("collectionId", out var idElement) || !idElement.TryGetInt64(out var id)) continue;
                var year = Text("releaseDate") is { Length: >= 4 } date && int.TryParse(date[..4], out var y) ? y : (int?)null;
                list.Add(new Album(id, Text("collectionName") ?? "", Text("artistName") ?? "", Text("artworkUrl100"), year));
            }
            return list;
        }
        finally { _gate.Release(); }
    }

    // The result that is this album: the title the same once editions are set aside (an exact
    // title first), and the same artist. Null when none is close enough.
    public static Album? BestMatch(IEnumerable<Album> results, string artist, string album) =>
        results.Where(r => r.ArtworkUrl100 is not null && ArtistMatches(artist, r.Artist) && TitleMatches(album, r.Title))
            .OrderByDescending(r => Comparable(MusicText.Key(r.Title)) == Comparable(MusicText.Key(album)))
            .FirstOrDefault();

    // "Rumours" is "Rumours (Super Deluxe)" and "Rumours - Remastered"; it is not "Rumours Live"
    // or "Rumours Revisited". Punctuation and "&"/"and" don't count.
    public static bool TitleMatches(string local, string candidate)
    {
        var a = Comparable(MusicText.EditionlessKey(local));
        return a.Length > 0 && a == Comparable(MusicText.EditionlessKey(candidate));
    }

    // The same artist, ignoring case, accents, punctuation, "&"/"and" and a leading "The".
    public static bool ArtistMatches(string local, string candidate)
    {
        if (MusicAlbumRules.IsVariousArtists(local) || MusicAlbumRules.IsVariousArtists(candidate))
            return MusicAlbumRules.IsVariousArtists(local) && MusicAlbumRules.IsVariousArtists(candidate);
        var a = Comparable(MusicText.SortKey(local));
        return a.Length > 0 && a == Comparable(MusicText.SortKey(candidate));
    }

    private static string Comparable(string text) => string.Join(' ', MusicText.Words(text).Where(w => w != "and"));

    // Apple's artwork URL at another size: .../100x100bb.jpg -> .../600x600bb.jpg. Null when the
    // URL isn't in that form (it would only ever be the 100 px picture).
    public static string? Artwork(string? artworkUrl100, int size) =>
        artworkUrl100 is not null && artworkUrl100.Contains("100x100bb", StringComparison.Ordinal)
            ? artworkUrl100.Replace("100x100bb", $"{size}x{size}bb", StringComparison.Ordinal)
            : null;

    // Looks the album up and saves its cover to `destination`. False when Apple has nothing
    // that matches well. Network trouble throws (HttpRequestException / timeout).
    public async Task<bool> FindCoverAsync(string artist, string album, string destination, CancellationToken cancellationToken)
    {
        var best = BestMatch(await SearchAsync(artist, album, cancellationToken), artist, album);
        if (best is null || MusicArtHosts.Normalize(Artwork(best.ArtworkUrl100, 600)) is not { } url) return false;
        var data = await downloader.GetAsync(url, cancellationToken);
        if (data is null) return false;
        try { await MusicArtImages.SaveAsJpegAsync(data, destination, cancellationToken); }
        catch (MusicCoverException ex)
        {
            logger.LogInformation("iTunes cover for {Album} could not be used: {Message}", album, ex.Message);
            return false;
        }
        logger.LogDebug("iTunes: saved the cover of {Album}", album);
        return true;
    }
}
