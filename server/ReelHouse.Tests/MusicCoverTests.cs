using System.Collections.Concurrent;
using System.Net;
using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using ReelHouse;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.PixelFormats;
using Xunit;

namespace ReelHouse.Tests;

// Album covers beyond what is in the files: the Cover Art Archive then Apple's iTunes search
// (only for a good match, and a network error is "try again later"), covers an admin uploads or
// picks (they beat everything and survive rescans), the hosts the server will download from,
// "find missing covers now", and art URLs that change when the cover does. Everything outside is
// a FakeInternet; nothing reaches the real one.
public sealed class MusicCoverTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"music-covers-{Guid.NewGuid():N}");
    private readonly string _library;
    private readonly string _data;
    private readonly string _settingsPath;

    public MusicCoverTests()
    {
        _library = Path.Combine(_root, "Music");
        _data = Path.Combine(_root, "data");
        Directory.CreateDirectory(_library);
        Directory.CreateDirectory(_data);
        _settingsPath = Path.Combine(_root, "appsettings.json");
        SetOnline(true);
    }

    public void Dispose()
    {
        try { TempDirectories.Delete(_root); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private void SetOnline(bool online) =>
        File.WriteAllText(_settingsPath, $$"""{ "Music": { "FetchArtworkOnline": {{(online ? "true" : "false")}}, "FetchLyricsOnline": false } }""");

    private static byte[] Png(int size, byte red)
    {
        using var image = new Image<Rgb24>(size, size, new Rgb24(red, 40, 90));
        using var stream = new MemoryStream();
        image.SaveAsPng(stream);
        return stream.ToArray();
    }

    // Every request any of the clients makes lands here; Route answers it (null is a 404).
    private sealed class FakeInternet : HttpMessageHandler
    {
        public readonly ConcurrentQueue<(DateTimeOffset At, Uri Uri)> Requests = new();
        public Func<Uri, HttpResponseMessage?> Route { get; set; } = _ => null;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Enqueue((DateTimeOffset.UtcNow, request.RequestUri!));
            return Task.FromResult(Route(request.RequestUri!) ?? new HttpResponseMessage(HttpStatusCode.NotFound));
        }

        public List<string> To(string host) => Requests.Select(r => r.Uri).Where(u => u.Host == host).Select(u => Uri.UnescapeDataString(u.AbsoluteUri)).ToList();
    }

    private sealed class Factory(HttpMessageHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }

    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private static HttpResponseMessage Bytes(byte[] data)
    {
        var content = new ByteArrayContent(data);
        content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("image/png");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
    }

    private static HttpResponseMessage Redirect(string to)
    {
        var response = new HttpResponseMessage(HttpStatusCode.TemporaryRedirect);
        response.Headers.Location = new Uri(to);
        return response;
    }

    private static string ITunesResults(params (long Id, string Title, string Artist, string Art)[] results) =>
        System.Text.Json.JsonSerializer.Serialize(new
        {
            resultCount = results.Length,
            results = results.Select(r => new { wrapperType = "collection", collectionType = "Album", collectionId = r.Id, collectionName = r.Title, artistName = r.Artist, artworkUrl100 = r.Art, releaseDate = "2016-04-23T07:00:00Z" })
        });

    private sealed record Rig(SqliteMusicStore Store, MusicScanner Scanner, MusicCoverService Covers, MusicArtCache Art, MediaFiles Files, MediaFileRelay Relay) : IDisposable
    {
        public async Task<MusicCatalog> CatalogAsync() => await new MusicCatalogCache(Store).GetAsync(Ct);

        public async Task<MusicArtRecord?> ArtAsync(MusicAlbumInfo album) => (await Store.GetArtAsync(Ct)).GetValueOrDefault(MusicArtCache.AlbumKey(album.Id));

        public async Task ScanAsync()
        {
            Assert.True(await Scanner.ScanAsync(null, Ct));
            Assert.Null(Scanner.LastError);
        }

        public void Dispose()
        {
            Scanner.Dispose();
            Relay.Dispose();
            Files.Network.Dispose();
            Store.Dispose();
        }
    }

    private async Task<Rig> NewRigAsync(FakeInternet internet)
    {
        var store = new SqliteMusicStore(_data);
        var computers = new MediaNetworkComputerStore(_data);
        var network = new MediaNetworkFileSystem(computers, new MediaNetworkResolver(NullLogger<MediaNetworkResolver>.Instance), NullLogger<MediaNetworkFileSystem>.Instance);
        var relay = new MediaFileRelay(network, NullLogger<MediaFileRelay>.Instance);
        var files = new MediaFiles(network, relay);
        var art = new MusicArtCache(Path.Combine(_data, "music-art"));
        var factory = new Factory(internet);
        var coverArt = new MusicCoverArtClient(factory, NullLogger<MusicCoverArtClient>.Instance);
        var downloader = new MusicArtDownloader(factory);
        var itunes = new MusicITunesArtClient(factory, downloader, NullLogger<MusicITunesArtClient>.Instance) { Spacing = TimeSpan.FromMilliseconds(10) };
        var settings = new AppSettingsFile(_settingsPath);
        var scanner = new MusicScanner(store, files, art, coverArt, itunes, settings, new ConfigurationBuilder().Build(), NullLogger<MusicScanner>.Instance);
        var covers = new MusicCoverService(store, scanner, settings, art, coverArt, itunes, downloader, NullLogger<MusicCoverService>.Instance);
        await store.SaveLibraryAsync(new MusicLibrary(Guid.NewGuid(), "Music", _library, DateTimeOffset.UtcNow), Ct);
        return new Rig(store, scanner, covers, art, files, relay);
    }

    private Task MakeAlbumAsync(string artist, string album, string? cover = null, double frequency = 440) =>
        MusicTestAudio.MakeAsync(Path.Combine(_library, artist, album, "01.mp3"), MusicTestAudio.Tags("One", artist, album, 1, artist), 3, cover, frequency);

    private static MusicAlbumInfo Album(MusicCatalog catalog, string title) => Assert.Single(catalog.Albums, a => a.Title == title);

    // MARK: - Matching and the rate gate (no files needed)

    [Fact]
    public void ITunesResults_AreUsedOnlyForTheSameAlbumAndArtist()
    {
        Assert.True(MusicITunesArtClient.TitleMatches("Rumours", "Rumours (Super Deluxe)"));
        Assert.True(MusicITunesArtClient.TitleMatches("Rumours", "Rumours - Remastered"));
        Assert.True(MusicITunesArtClient.TitleMatches("Rumours (2004 Remaster)", "Rumours"));
        Assert.True(MusicITunesArtClient.TitleMatches("Sgt. Pepper's Lonely Hearts Club Band", "Sgt Pepper's Lonely Hearts Club Band"));
        Assert.False(MusicITunesArtClient.TitleMatches("Rumours", "Rumours Live"));
        Assert.False(MusicITunesArtClient.TitleMatches("Greatest Hits", "Greatest Hits, Vol. 2"));
        Assert.False(MusicITunesArtClient.TitleMatches("Tusk", "Rumours"));
        Assert.False(MusicITunesArtClient.TitleMatches("", ""));
        // An album filed with its year: matched, and searched for, without it.
        Assert.True(MusicITunesArtClient.TitleMatches("Eagles (1972)", "Eagles"));
        var search = MusicITunesArtClient.SearchUrl("Eagles", "Eagles (1972)");
        Assert.Contains("term=Eagles%20Eagles&", search);
        Assert.DoesNotContain("1972", search);

        Assert.True(MusicITunesArtClient.ArtistMatches("Simon & Garfunkel", "Simon and Garfunkel"));
        Assert.True(MusicITunesArtClient.ArtistMatches("Beyonce", "Beyoncé"));
        Assert.True(MusicITunesArtClient.ArtistMatches("The Beatles", "Beatles"));
        Assert.True(MusicITunesArtClient.ArtistMatches("Various Artists", "Various Artists"));
        Assert.False(MusicITunesArtClient.ArtistMatches("Various Artists", "Fleetwood Mac"));
        Assert.False(MusicITunesArtClient.ArtistMatches("Fleetwood Mac", "Fleetwood Mac Tribute Band"));

        const string art = "https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg";
        var results = new List<MusicITunesArtClient.Album>
        {
            new(1, "Rumours Live", "Fleetwood Mac", art, 1977),
            new(2, "Rumours", "A Tribute Band", art, 2010),
            new(3, "Rumours (Super Deluxe)", "Fleetwood Mac", art, 2013),
            new(4, "Rumours", "Fleetwood Mac", art, 1977),
            new(5, "Rumours", "Fleetwood Mac", null, 1977)
        };
        Assert.Equal(4, MusicITunesArtClient.BestMatch(results, "Fleetwood Mac", "Rumours")!.Id);   // the exact title first
        Assert.Equal(3, MusicITunesArtClient.BestMatch(results.Take(3), "Fleetwood Mac", "Rumours")!.Id);
        Assert.Null(MusicITunesArtClient.BestMatch(results.Take(2), "Fleetwood Mac", "Rumours"));
        Assert.Null(MusicITunesArtClient.BestMatch(results.Skip(4), "Fleetwood Mac", "Rumours"));   // no artwork

        Assert.Equal("https://is1-ssl.mzstatic.com/image/thumb/a/600x600bb.jpg", MusicITunesArtClient.Artwork(art, 600));
        Assert.Null(MusicITunesArtClient.Artwork("https://is1-ssl.mzstatic.com/image/thumb/a/cover.jpg", 600));
        Assert.Equal("https://itunes.apple.com/search?term=Fleetwood%20Mac%20Rumours&entity=album&limit=10&media=music",
            MusicITunesArtClient.SearchUrl("Fleetwood Mac", "Rumours"));
    }

    [Fact]
    public async Task ITunesSearches_AreKeptApart()
    {
        Assert.True(MusicITunesArtClient.DefaultSpacing >= TimeSpan.FromSeconds(3));
        var internet = new FakeInternet { Route = _ => Json("""{ "resultCount": 0, "results": [] }""") };
        var factory = new Factory(internet);
        var itunes = new MusicITunesArtClient(factory, new MusicArtDownloader(factory), NullLogger<MusicITunesArtClient>.Instance)
        {
            Spacing = TimeSpan.FromMilliseconds(300)
        };

        await Task.WhenAll(Enumerable.Range(0, 3).Select(i => itunes.SearchAsync("Artist", $"Album {i}", Ct)));

        var times = internet.Requests.Select(r => r.At).OrderBy(t => t).ToList();
        Assert.Equal(3, times.Count);
        for (var i = 1; i < times.Count; i++)
            Assert.True(times[i] - times[i - 1] >= TimeSpan.FromMilliseconds(280), $"searches {i - 1} and {i} were {(times[i] - times[i - 1]).TotalMilliseconds} ms apart");
    }

    [Fact]
    public async Task CoverDownloads_StayOnTheCoverHosts_RedirectsIncluded()
    {
        var png = Png(40, 200);
        var internet = new FakeInternet
        {
            Route = uri => uri.AbsoluteUri switch
            {
                "https://coverartarchive.org/release/r/1-1200.jpg" => Redirect("https://archive.org/download/r/1.jpg"),
                // An http hop on an allowed host is taken as https.
                "https://archive.org/download/r/1.jpg" => Redirect("http://ia800.us.archive.org/r/1.jpg"),
                "https://ia800.us.archive.org/r/1.jpg" => Bytes(png),
                "https://coverartarchive.org/release/r/2-1200.jpg" => Redirect("https://evil.example/steal"),
                "https://is1-ssl.mzstatic.com/big.jpg" => Bytes(new byte[MusicArtDownloader.MaxBytes + 1]),
                _ => null
            }
        };
        var downloader = new MusicArtDownloader(new Factory(internet));

        Assert.Equal(png, await downloader.GetAsync(new Uri("https://coverartarchive.org/release/r/1-1200.jpg"), Ct));
        Assert.Null(await downloader.GetAsync(new Uri("https://coverartarchive.org/release/r/missing.jpg"), Ct));
        await Assert.ThrowsAsync<MusicCoverException>(() => downloader.GetAsync(new Uri("https://coverartarchive.org/release/r/2-1200.jpg"), Ct));
        foreach (var refused in new[] { "https://evil.example/x.jpg", "http://coverartarchive.org/x.jpg", "https://coverartarchive.org.evil.example/x.jpg",
                     "https://coverartarchive.org:8443/x.jpg", "https://mzstatic.com.evil.example/x.jpg" })
            await Assert.ThrowsAsync<MusicCoverException>(() => downloader.GetAsync(new Uri(refused), Ct));
        await Assert.ThrowsAsync<MusicCoverException>(() => downloader.GetAsync(new Uri("https://is1-ssl.mzstatic.com/big.jpg"), Ct));
        Assert.DoesNotContain(internet.Requests, r => r.Uri.Host.Contains("evil", StringComparison.Ordinal) || !r.Uri.IsDefaultPort || r.Uri.Scheme != "https");

        Assert.Equal("https://coverartarchive.org/a.jpg", MusicArtHosts.Normalize("http://coverartarchive.org/a.jpg")!.AbsoluteUri);
        Assert.Null(MusicArtHosts.Normalize("file:///etc/passwd"));
        Assert.Null(MusicArtHosts.Normalize("https://user@coverartarchive.org/a.jpg"));
    }

    [Fact]
    public async Task OnlyRealPictures_AreKept_AsJpegsNoBiggerThan1500()
    {
        var destination = Path.Combine(_root, "cover.jpg");
        await Assert.ThrowsAsync<MusicCoverException>(() => MusicArtImages.SaveAsJpegAsync(Encoding.UTF8.GetBytes("<html>not a picture</html>"), destination, Ct));
        await Assert.ThrowsAsync<MusicCoverException>(() => MusicArtImages.SaveAsJpegAsync([], destination, Ct));
        byte[] gif;
        using (var image = new Image<Rgb24>(20, 20))
        using (var stream = new MemoryStream())
        {
            image.SaveAsGif(stream);
            gif = stream.ToArray();
        }
        await Assert.ThrowsAsync<MusicCoverException>(() => MusicArtImages.SaveAsJpegAsync(gif, destination, Ct));
        Assert.False(File.Exists(destination));

        await MusicArtImages.SaveAsJpegAsync(Png(2000, 10), destination, Ct);
        using var saved = await Image.LoadAsync(destination, Ct);
        Assert.Equal((1500, 1500), (saved.Width, saved.Height));
        Assert.IsType<SixLabors.ImageSharp.Formats.Jpeg.JpegFormat>(saved.Metadata.DecodedImageFormat);
    }

    // Albums marked "no cover" before the iTunes source existed are re-asked once, on the next
    // scan, rather than a month later.
    [Fact]
    public async Task AnOlderLibrary_RechecksCoverlessAlbumsOnce()
    {
        var now = DateTimeOffset.UtcNow;
        using (var store = new SqliteMusicStore(_data))
        {
            await store.SetArtAsync(new MusicArtRecord("album:bare", null, MusicArtSources.None, now), Ct);
            await store.SetArtAsync(new MusicArtRecord("album:found", "/art/f.jpg", MusicArtSources.CoverArtArchive, now), Ct);
        }
        // A music.db from before the recheck.
        using (var connection = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={Path.Combine(_data, "music.db")};Pooling=False"))
        {
            connection.Open();
            using var forget = connection.CreateCommand();
            forget.CommandText = "DELETE FROM MusicState WHERE Key = 'art.itunesRecheck'";
            forget.ExecuteNonQuery();
        }
        using (var store = new SqliteMusicStore(_data))
        {
            var art = await store.GetArtAsync(Ct);
            Assert.True(art["album:bare"].CheckedAt < now.AddYears(-1));
            Assert.True(art["album:found"].CheckedAt >= now.AddSeconds(-5));
            await store.SetArtAsync(new MusicArtRecord("album:bare", null, MusicArtSources.None, now), Ct);
        }
        // Only once.
        using (var store = new SqliteMusicStore(_data))
            Assert.True((await store.GetArtAsync(Ct))["album:bare"].CheckedAt >= now.AddSeconds(-5));
    }

    [Fact]
    public async Task APinnedRecord_IsNeverReplacedOrDeletedByTheAutomaticOnes()
    {
        using var store = new SqliteMusicStore(_data);
        var now = DateTimeOffset.UtcNow;
        await store.SetArtAsync(new MusicArtRecord("album:x", "/art/x.pinned.jpg", MusicArtSources.Custom, now), Ct);
        await store.SetArtAsync(new MusicArtRecord("album:x", "/art/x.jpg", MusicArtSources.Embedded, now), Ct);
        await store.SetArtAsync(new MusicArtRecord("album:x", null, MusicArtSources.None, now), Ct);
        Assert.Equal(MusicArtSources.Custom, (await store.GetArtAsync(Ct))["album:x"].Source);
        await store.SetArtAsync(new MusicArtRecord("album:x", "/art/x.pinned.jpg", MusicArtSources.Chosen, now), Ct);
        Assert.Equal(MusicArtSources.Chosen, (await store.GetArtAsync(Ct))["album:x"].Source);

        await store.DeleteArtAsync(["album:x"], includePinned: false, Ct);
        Assert.True((await store.GetArtAsync(Ct)).ContainsKey("album:x"));
        await store.DeleteArtAsync(["album:x"], includePinned: true, Ct);
        Assert.False((await store.GetArtAsync(Ct)).ContainsKey("album:x"));
    }

    [Fact]
    public void ArtUrls_CarryAVersion_ThatChangesWithTheCover()
    {
        var track = new MusicTrack
        {
            Id = Guid.NewGuid(), Path = "/music/a/1.mp3", RelativePath = "a/1.mp3", AddedAt = DateTimeOffset.UtcNow, TagsReadAt = DateTimeOffset.UtcNow,
            Title = "One", ArtistText = "Band", Album = "Record", Codec = "mp3", DurationSeconds = 100
        };
        MusicAlbumRules.Resolve([track]);
        var key = MusicArtCache.AlbumKey(track.AlbumId);
        MusicCatalog Catalog(params MusicArtRecord[] records) => new(1, [track], records.ToDictionary(r => r.Key), []);
        string? Url(params MusicArtRecord[] records) => MusicView.AlbumArtUrlOf(Catalog(records).AlbumsById[track.AlbumId]);
        var at = DateTimeOffset.UtcNow;

        var embedded = Url(new MusicArtRecord(key, "/data/music-art/a.jpg", MusicArtSources.Embedded, at));
        Assert.Matches($"^/api/music/albums/{track.AlbumId}/art\\?v=[0-9a-f]{{8}}$", embedded);
        Assert.Equal(embedded, Url(new MusicArtRecord(key, "/data/music-art/a.jpg", MusicArtSources.Embedded, at)));
        Assert.NotEqual(embedded, Url(new MusicArtRecord(key, "/data/music-art/a.pinned.jpg", MusicArtSources.Custom, at)));
        Assert.NotEqual(embedded, Url(new MusicArtRecord(key, "/data/music-art/a.jpg", MusicArtSources.Embedded, at.AddSeconds(1))));
        Assert.Null(Url(new MusicArtRecord(key, null, MusicArtSources.None, at)));
        Assert.Null(Url());

        // An artist with no picture of their own shows (and versions) their album's cover.
        var catalog = Catalog(new MusicArtRecord(key, "/data/music-art/a.jpg", MusicArtSources.Embedded, at));
        var artist = catalog.ArtistsById[MusicIds.Artist("Band")];
        Assert.Equal(catalog.AlbumsById[track.AlbumId].ArtVersion, catalog.ArtistArtVersion(artist));
    }

    // MARK: - The scanner's online sources

    [Fact]
    public async Task Online_TheArchiveFirst_ThenITunes_AndOnlyForAGoodMatch()
    {
        if (!await MusicTestAudio.FfmpegAvailableAsync()) Assert.Skip("needs a real ffmpeg on PATH");
        await MakeAlbumAsync("Fleetwood Mac", "Rumours");           // the archive has it
        await MakeAlbumAsync("Beyoncé", "Lemonade");                // MusicBrainz doesn't know it; Apple does
        await MakeAlbumAsync("Tribute", "Echoes");                  // MusicBrainz knows it, the archive has no picture; Apple does
        await MakeAlbumAsync("Some Band", "Obscure Thing");         // Apple has only near misses
        var internet = new FakeInternet
        {
            Route = uri =>
            {
                var url = Uri.UnescapeDataString(uri.AbsoluteUri);
                if (uri.Host == "musicbrainz.org")
                    return Json(url.Contains("\"Rumours\"") ? """{ "release-groups": [ { "id": "rg-rumours", "score": 100, "title": "Rumours" } ] }"""
                        : url.Contains("\"Echoes\"") ? """{ "release-groups": [ { "id": "rg-echoes", "score": 100, "title": "Echoes" } ] }"""
                        : """{ "release-groups": [] }""");
                if (uri.AbsoluteUri == "https://coverartarchive.org/release-group/rg-rumours/front-500") return Bytes(Png(500, 1));
                if (uri.Host == "itunes.apple.com")
                    return Json(url.Contains("Lemonade") ? ITunesResults((11, "Lemonade", "Beyoncé", "https://is1-ssl.mzstatic.com/image/thumb/lemonade/100x100bb.jpg"))
                        : url.Contains("Echoes") ? ITunesResults((12, "Echoes (Deluxe Edition)", "Tribute", "https://is1-ssl.mzstatic.com/image/thumb/echoes/100x100bb.jpg"))
                        : url.Contains("Obscure") ? ITunesResults((13, "Obscure Thing Live", "Some Band", "https://is1-ssl.mzstatic.com/image/thumb/live/100x100bb.jpg"),
                            (14, "Obscure Thing", "Other Band", "https://is1-ssl.mzstatic.com/image/thumb/other/100x100bb.jpg"))
                        : ITunesResults());
                if (uri.Host == "is1-ssl.mzstatic.com" && uri.AbsolutePath.EndsWith("/600x600bb.jpg", StringComparison.Ordinal)) return Bytes(Png(600, 2));
                return null;
            }
        };
        using var rig = await NewRigAsync(internet);
        await rig.ScanAsync();
        var catalog = await rig.CatalogAsync();

        Assert.Equal(MusicArtSources.CoverArtArchive, (await rig.ArtAsync(Album(catalog, "Rumours")))!.Source);
        var lemonade = (await rig.ArtAsync(Album(catalog, "Lemonade")))!;
        Assert.Equal(MusicArtSources.ITunes, lemonade.Source);
        Assert.Equal(MusicArtSources.ITunes, (await rig.ArtAsync(Album(catalog, "Echoes")))!.Source);
        var obscure = (await rig.ArtAsync(Album(catalog, "Obscure Thing")))!;
        Assert.Equal((MusicArtSources.None, null), (obscure.Source, obscure.Path));

        // Apple was never asked about the album the archive had, and only ever for 600x600.
        var searches = internet.To("itunes.apple.com");
        Assert.Equal(3, searches.Count);
        Assert.DoesNotContain(searches, s => s.Contains("Rumours"));
        Assert.All(internet.To("is1-ssl.mzstatic.com"), u => Assert.EndsWith("/600x600bb.jpg", u));
        Assert.DoesNotContain(internet.To("is1-ssl.mzstatic.com"), u => u.Contains("/live/") || u.Contains("/other/"));
        using var image = await Image.LoadAsync(lemonade.Path!, Ct);
        Assert.Equal(600, image.Width);
        Assert.Equal(lemonade.Path, Album(catalog, "Lemonade").ArtPath);
    }

    [Fact]
    public async Task NetworkTrouble_IsTriedAgainNextScan_NeverRecordedAsNone()
    {
        if (!await MusicTestAudio.FfmpegAvailableAsync()) Assert.Skip("needs a real ffmpeg on PATH");
        await MakeAlbumAsync("Band", "Archive Down");
        await MakeAlbumAsync("Band", "Apple Down");
        var down = true;
        var internet = new FakeInternet
        {
            Route = uri =>
            {
                var url = Uri.UnescapeDataString(uri.AbsoluteUri);
                if (uri.Host == "musicbrainz.org")
                    return down && url.Contains("Archive Down") ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) : Json("""{ "release-groups": [] }""");
                if (uri.Host == "itunes.apple.com")
                    return down ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
                        : Json(ITunesResults((21, url.Contains("Apple Down") ? "Apple Down" : "Archive Down", "Band", "https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg")));
                if (uri.Host == "is1-ssl.mzstatic.com") return Bytes(Png(600, 3));
                return null;
            }
        };
        using var rig = await NewRigAsync(internet);
        await rig.ScanAsync();
        var catalog = await rig.CatalogAsync();
        Assert.Null(await rig.ArtAsync(Album(catalog, "Archive Down")));
        Assert.Null(await rig.ArtAsync(Album(catalog, "Apple Down")));

        // Back up: the next scan looks again, without waiting the month a "none" waits.
        down = false;
        await rig.ScanAsync();
        catalog = await rig.CatalogAsync();
        Assert.Equal(MusicArtSources.ITunes, (await rig.ArtAsync(Album(catalog, "Archive Down")))!.Source);
        Assert.Equal(MusicArtSources.ITunes, (await rig.ArtAsync(Album(catalog, "Apple Down")))!.Source);
    }

    // MusicBrainz answers 503 often. That alone mustn't keep an album bare when Apple has it; and
    // when Apple has nothing either, the album comes up again in a day, not a month.
    [Fact]
    public async Task MusicBrainzDown_StillTriesITunes()
    {
        if (!await MusicTestAudio.FfmpegAvailableAsync()) Assert.Skip("needs a real ffmpeg on PATH");
        await MakeAlbumAsync("Band", "On Apple");
        await MakeAlbumAsync("Band", "Nowhere");
        var internet = new FakeInternet
        {
            Route = uri =>
            {
                var url = Uri.UnescapeDataString(uri.AbsoluteUri);
                if (uri.Host == "musicbrainz.org") return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
                if (uri.Host == "itunes.apple.com")
                    return url.Contains("On Apple")
                        ? Json(ITunesResults((31, "On Apple", "Band", "https://is1-ssl.mzstatic.com/image/thumb/y/100x100bb.jpg")))
                        : Json("""{ "resultCount": 0, "results": [] }""");
                if (uri.Host == "is1-ssl.mzstatic.com") return Bytes(Png(600, 5));
                return null;
            }
        };
        using var rig = await NewRigAsync(internet);
        await rig.ScanAsync();
        var catalog = await rig.CatalogAsync();
        Assert.Equal(MusicArtSources.ITunes, (await rig.ArtAsync(Album(catalog, "On Apple")))!.Source);
        var nowhere = (await rig.ArtAsync(Album(catalog, "Nowhere")))!;
        Assert.Equal(MusicArtSources.None, nowhere.Source);
        Assert.True(nowhere.CheckedAt < DateTimeOffset.UtcNow - TimeSpan.FromDays(28), "due again within a day or so");
    }

    // MARK: - Covers set by hand

    [Fact]
    public async Task HandSetCovers_BeatEmbeddedArt_SurviveRescans_AndResetLooksAgain()
    {
        if (!await MusicTestAudio.FfmpegAvailableAsync()) Assert.Skip("needs a real ffmpeg on PATH");
        var blue = Path.Combine(_root, "blue.png");
        await MusicTestAudio.MakeImageAsync(blue, "blue");
        await MakeAlbumAsync("Alpha", "First", blue);
        await MakeAlbumAsync("Beta", "Second", blue);
        var internet = new FakeInternet
        {
            Route = uri =>
            {
                var url = Uri.UnescapeDataString(uri.AbsoluteUri);
                if (uri.Host == "musicbrainz.org")
                    return Json(url.Contains("\"Second\"") ? """{ "release-groups": [ { "id": "rg-second", "score": 100, "title": "Second" } ] }""" : """{ "release-groups": [] }""");
                if (uri.AbsoluteUri == "https://coverartarchive.org/release-group/rg-second")
                    return Json("""
                        { "images": [
                          { "id": 111, "front": true, "types": ["Front"], "image": "http://coverartarchive.org/release/r1/111.jpg",
                            "thumbnails": { "250": "http://coverartarchive.org/release/r1/111-250.jpg", "1200": "http://coverartarchive.org/release/r1/111-1200.jpg" } },
                          { "id": 222, "front": false, "types": ["Back"], "image": "https://evil.example/back.jpg",
                            "thumbnails": { "250": "https://evil.example/back-250.jpg", "1200": "https://evil.example/back-1200.jpg" } }
                        ], "release": "https://musicbrainz.org/release/r1" }
                        """);
                if (uri.AbsoluteUri == "https://coverartarchive.org/release/r1/111-1200.jpg") return Redirect("https://archive.org/download/r1/111-1200.jpg");
                if (uri.AbsoluteUri == "https://archive.org/download/r1/111-1200.jpg") return Bytes(Png(1200, 4));
                if (uri.Host == "itunes.apple.com") return Json(ITunesResults());
                return null;
            }
        };
        using var rig = await NewRigAsync(internet);
        await rig.ScanAsync();
        var catalog = await rig.CatalogAsync();
        Assert.Equal(MusicArtSources.Embedded, Album(catalog, "First").ArtSource);
        Assert.Equal(MusicArtSources.Embedded, Album(catalog, "Second").ArtSource);
        var embeddedUrl = MusicView.AlbumArtUrlOf(Album(catalog, "First"));

        // An upload replaces the embedded picture.
        var first = Album(catalog, "First");
        var custom = await rig.Covers.UploadAsync(first, Png(300, 5), Ct);
        Assert.Equal((MusicArtSources.Custom, rig.Art.PinnedAlbumPath(first.Id)), (custom.Source, custom.Path));
        await Assert.ThrowsAsync<MusicCoverException>(() => rig.Covers.UploadAsync(first, Encoding.UTF8.GetBytes("hello"), Ct));
        Assert.Equal(MusicArtSources.Custom, (await rig.ArtAsync(first))!.Source);

        // Picking: only what was offered, and only from the cover hosts.
        var second = Album(catalog, "Second");
        var offered = await rig.Covers.CandidatesAsync(second, Ct);
        Assert.Null(offered.Note);
        var candidate = Assert.Single(offered.Candidates);
        Assert.Equal(("caa-111", MusicArtSources.CoverArtArchive, "https://coverartarchive.org/release/r1/111-250.jpg"),
            (candidate.Id, candidate.Source, candidate.Thumb.AbsoluteUri));
        Assert.Null(await rig.Covers.ChooseAsync(second, "caa-222", Ct));
        Assert.Null(await rig.Covers.ChooseAsync(second, "https://evil.example/back-1200.jpg", Ct));
        Assert.Null(await rig.Covers.ChooseAsync(second, "itunes-999", Ct));
        var chosen = (await rig.Covers.ChooseAsync(second, "caa-111", Ct))!;
        Assert.Equal(MusicArtSources.Chosen, chosen.Source);
        Assert.DoesNotContain(internet.Requests, r => r.Uri.Host.Contains("evil", StringComparison.Ordinal));
        using (var image = await Image.LoadAsync(chosen.Path!, Ct)) Assert.Equal(1200, image.Width);

        // The files change (re-tagged, re-encoded) and are scanned again: the hand-set covers stay.
        await MakeAlbumAsync("Alpha", "First", blue, frequency: 660);
        await MakeAlbumAsync("Beta", "Second", blue, frequency: 660);
        await rig.ScanAsync();
        catalog = await rig.CatalogAsync();
        Assert.Equal((MusicArtSources.Custom, custom.Path), (Album(catalog, "First").ArtSource, Album(catalog, "First").ArtPath));
        Assert.Equal((MusicArtSources.Chosen, chosen.Path), (Album(catalog, "Second").ArtSource, Album(catalog, "Second").ArtPath));
        var customUrl = MusicView.AlbumArtUrlOf(Album(catalog, "First"));
        Assert.NotEqual(embeddedUrl, customUrl);

        // A new upload gets new sized copies; the old ones go.
        var oldSized = await rig.Art.SizedAsync(custom.Path!, LocalMediaFileSystem.Instance, 128, Ct);
        Assert.NotEqual(custom.Path, oldSized);
        await Task.Delay(20, Ct);
        await rig.Covers.UploadAsync(first, Png(400, 6), Ct);
        var newSized = await rig.Art.SizedAsync(custom.Path!, LocalMediaFileSystem.Instance, 128, Ct);
        Assert.NotEqual(oldSized, newSized);
        Assert.False(File.Exists(oldSized));
        catalog = await rig.CatalogAsync();
        Assert.NotEqual(customUrl, MusicView.AlbumArtUrlOf(Album(catalog, "First")));

        // Reset to automatic: looked up again at once, and the embedded picture is back.
        var reset = await rig.Covers.ResetAsync(Album(catalog, "First"), Ct);
        Assert.Equal(MusicArtSources.Embedded, reset!.Source);
        Assert.False(File.Exists(custom.Path));
        catalog = await rig.CatalogAsync();
        Assert.Equal(MusicArtSources.Embedded, Album(catalog, "First").ArtSource);
        Assert.Equal(MusicArtSources.Chosen, Album(catalog, "Second").ArtSource);
    }

    [Fact]
    public async Task Candidates_SayWhichProviderFailed_AndStillListTheOther()
    {
        if (!await MusicTestAudio.FfmpegAvailableAsync()) Assert.Skip("needs a real ffmpeg on PATH");
        var blue = Path.Combine(_root, "blue.png");
        await MusicTestAudio.MakeImageAsync(blue, "blue");
        await MakeAlbumAsync("Beyoncé", "Lemonade", blue);
        var internet = new FakeInternet
        {
            Route = uri => uri.Host switch
            {
                "musicbrainz.org" => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable),
                "itunes.apple.com" => Json(ITunesResults(
                    (31, "Lemonade", "Beyoncé", "https://is1-ssl.mzstatic.com/image/thumb/l/100x100bb.jpg"),
                    (32, "Something Else", "Nobody", "https://is1-ssl.mzstatic.com/image/thumb/n/100x100bb.jpg"))),
                _ => null
            }
        };
        using var rig = await NewRigAsync(internet);
        await rig.ScanAsync();
        var lemonade = Album(await rig.CatalogAsync(), "Lemonade");

        var offered = await rig.Covers.CandidatesAsync(lemonade, Ct);
        Assert.Contains("Cover Art Archive", offered.Note);
        var only = Assert.Single(offered.Candidates);
        Assert.Equal(("itunes-31", MusicArtSources.ITunes, "https://is1-ssl.mzstatic.com/image/thumb/l/300x300bb.jpg"),
            (only.Id, only.Source, only.Thumb.AbsoluteUri));
        Assert.Contains("Lemonade", only.Label);

        // Online lookups off: nothing is asked, and the note says why.
        SetOnline(false);
        var before = internet.Requests.Count;
        var off = await rig.Covers.CandidatesAsync(lemonade, Ct);
        Assert.Empty(off.Candidates);
        Assert.NotNull(off.Note);
        Assert.Equal(before, internet.Requests.Count);
    }

    // MARK: - Find missing covers now

    [Fact]
    public async Task FindMissingCoversNow_QueuesOnlyAlbumsWithoutACover()
    {
        if (!await MusicTestAudio.FfmpegAvailableAsync()) Assert.Skip("needs a real ffmpeg on PATH");
        SetOnline(false);
        await MakeAlbumAsync("Has", "Cover");
        await MusicTestAudio.MakeImageAsync(Path.Combine(_library, "Has", "Cover", "cover.jpg"), "green");
        await MakeAlbumAsync("Bare", "One");
        await MakeAlbumAsync("Bare", "Two");
        using var rig = await NewRigAsync(new FakeInternet());
        await rig.ScanAsync();
        var catalog = await rig.CatalogAsync();
        var withCover = (await rig.ArtAsync(Album(catalog, "Cover")))!;
        Assert.Equal(MusicArtSources.Folder, withCover.Source);
        Assert.Equal(MusicArtSources.None, (await rig.ArtAsync(Album(catalog, "One")))!.Source);

        // A cover.jpg turns up later. The album's files didn't change, so a scan alone waits a month.
        await MusicTestAudio.MakeImageAsync(Path.Combine(_library, "Bare", "One", "cover.jpg"), "yellow");
        await rig.ScanAsync();
        Assert.Equal(MusicArtSources.None, (await rig.ArtAsync(Album(catalog, "One")))!.Source);

        Assert.Equal(2, await rig.Scanner.QueueMissingArtAsync(Ct));
        Assert.Equal(withCover, await rig.ArtAsync(Album(catalog, "Cover")));
        Assert.Null(await rig.ArtAsync(Album(catalog, "One")));
        Assert.True(await rig.Scanner.RunArtworkPassAsync(Ct));

        Assert.Equal(MusicArtSources.Folder, (await rig.ArtAsync(Album(catalog, "One")))!.Source);
        Assert.Equal(MusicArtSources.None, (await rig.ArtAsync(Album(catalog, "Two")))!.Source);
        Assert.Equal(withCover, await rig.ArtAsync(Album(catalog, "Cover")));
        Assert.Equal(1, await rig.Scanner.QueueMissingArtAsync(Ct));
    }
}
