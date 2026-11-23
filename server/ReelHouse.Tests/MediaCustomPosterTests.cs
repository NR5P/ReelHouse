using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using ReelHouse;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.PixelFormats;
using Xunit;
using WebProgram = Program;

namespace ReelHouse.Tests;

// An admin's own poster for a movie or show: one uploaded, or one picked from TMDB's list. Either
// beats a poster file beside the video, which beats TMDB's default; a rescan or a metadata
// refresh never takes it away; "Reset to automatic" does. Also the art cache that used to keep
// serving the old title's poster after "Fix match", and "Find missing posters now".
public sealed class MediaCustomPosterTests : IDisposable
{
    private readonly string _root;
    private readonly string _settingsPath;
    private readonly string _dataDirectory;
    private readonly string _movies;
    private readonly FakeTmdb _tmdb = new();

    public MediaCustomPosterTests()
    {
        _root = Path.Combine(Path.GetTempPath(), $"media-posters-{Guid.NewGuid():N}");
        _dataDirectory = Path.Combine(_root, "data");
        _movies = Path.Combine(_root, "library", "Movies");
        Directory.CreateDirectory(_dataDirectory);
        Directory.CreateDirectory(_movies);
        _settingsPath = Path.Combine(_root, "appsettings.json");
        File.WriteAllText(_settingsPath, """{ "Auth": { "Enabled": false }, "Media": { "Enabled": true, "TmdbApiKey": "test-key" } }""");
    }

    public void Dispose()
    {
        try { TempDirectories.Delete(_root); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private WebApplicationFactory<WebProgram> CreateFactory() => new WebApplicationFactory<WebProgram>()
        .WithWebHostBuilder(builder => builder
            .UseTestSettings(_settingsPath, _dataDirectory)
            .ConfigureTestServices(services =>
                services.AddHttpClient(TmdbClient.HttpClientName).ConfigurePrimaryHttpMessageHandler(() => _tmdb)));

    // MARK: - Pictures

    private static byte[] Png(int width, int height, Rgba32 color)
    {
        using var image = new Image<Rgba32>(width, height, color);
        using var stream = new MemoryStream();
        image.SaveAsPng(stream);
        return stream.ToArray();
    }

    private static readonly Rgba32 Red = new(220, 20, 20);
    private static readonly Rgba32 Green = new(20, 200, 20);
    private static readonly Rgba32 Blue = new(20, 20, 220);

    // MARK: - The library

    private sealed record Seeded(Guid Coco, Guid Up, Guid Nothing, byte[] CocoLocalPoster);

    // Coco has a poster.jpg beside it and is matched to TMDB 1; Up has no local art and is
    // matched to TMDB 2; "Nothing" never matched and has no poster at all.
    private async Task<Seeded> SeedAsync(IMediaStore store)
    {
        var library = new MediaLibrary(Guid.NewGuid(), "Movies", MediaLibraryKinds.Movies, _movies, DateTimeOffset.UtcNow);
        foreach (var name in new[] { "Coco (2017)", "Up (2009)", "Nothing (2001)" })
        {
            Directory.CreateDirectory(Path.Combine(_movies, name));
            await File.WriteAllBytesAsync(Path.Combine(_movies, name, name + ".mkv"), [1, 2, 3], Ct);
        }
        var localPoster = Png(4, 6, Blue);
        await File.WriteAllBytesAsync(Path.Combine(_movies, "Coco (2017)", "poster.jpg"), localPoster, Ct);

        await store.SaveLibraryAsync(library, Ct);
        var items = MediaScanner.WalkMovies(library);
        await store.UpsertItemsAsync(items, Ct);
        var coco = items.Single(i => i.Title == "Coco");
        var up = items.Single(i => i.Title == "Up");
        var nothing = items.Single(i => i.Title == "Nothing");
        Assert.NotNull(coco.PosterLocal);

        foreach (var (item, tmdbId, poster) in new[] { (coco, 1, "/coco-default.jpg"), (up, 2, "/up-default.jpg") })
        {
            item.TmdbId = tmdbId;
            item.PosterRemote = poster;
            item.MetadataFetchedAt = DateTimeOffset.UtcNow;
            await store.UpdateMetadataAsync(item, Ct);
        }
        nothing.MetadataFetchedAt = DateTimeOffset.UtcNow;
        nothing.MetadataError = "No match found on TMDB.";
        await store.UpdateMetadataAsync(nothing, Ct);
        return new Seeded(coco.Id, up.Id, nothing.Id, localPoster);
    }

    private static async Task<JsonElement> GetJsonAsync(HttpClient client, string url)
    {
        using var response = await client.GetAsync(url, Ct);
        var body = await response.Content.ReadAsStringAsync(Ct);
        Assert.True(response.IsSuccessStatusCode, $"GET {url} -> {(int)response.StatusCode}: {body}");
        return JsonDocument.Parse(body).RootElement.Clone();
    }

    private static async Task<JsonElement> OkJsonAsync(HttpResponseMessage response)
    {
        var body = await response.Content.ReadAsStringAsync(Ct);
        Assert.True(response.IsSuccessStatusCode, $"{response.RequestMessage?.Method} {response.RequestMessage?.RequestUri} -> {(int)response.StatusCode}: {body}");
        return JsonDocument.Parse(body).RootElement.Clone();
    }

    private static async Task<byte[]> PosterBytesAsync(HttpClient client, Guid id, string query = "")
    {
        using var response = await client.GetAsync($"/api/media/items/{id}/poster{query}", Ct);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        return await response.Content.ReadAsByteArrayAsync(Ct);
    }

    private static Task<HttpResponseMessage> UploadAsync(HttpClient client, Guid id, byte[] bytes, string contentType)
    {
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        return client.PostAsync($"/api/media/items/{id}/poster", content, Ct);
    }

    private static string Source(JsonElement detail) => detail.GetProperty("posterSource").GetString()!;

    private static string PosterUrl(JsonElement detail) => detail.GetProperty("posterUrl").GetString()!;

    // MARK: - End to end

    [Fact]
    public async Task APickedOrUploadedPoster_BeatsTheLocalFile_AndResetGoesBackToIt()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var seeded = await SeedAsync(factory.Services.GetRequiredService<IMediaStore>());
        var coco = seeded.Coco;

        // Automatic: the poster.jpg beside the video beats TMDB's default.
        var detail = await GetJsonAsync(client, $"/api/media/items/{coco}");
        Assert.Equal("local", Source(detail));
        var localUrl = PosterUrl(detail);
        Assert.Equal(seeded.CocoLocalPoster, await PosterBytesAsync(client, coco));

        // The picker lists TMDB's posters with the one on show marked (none: it is the local file).
        var choices = await GetJsonAsync(client, $"/api/media/items/{coco}/posters");
        Assert.Equal("local", choices.GetProperty("current").GetProperty("source").GetString());
        Assert.Equal(JsonValueKind.Null, choices.GetProperty("current").GetProperty("tmdbPath").ValueKind);
        var listed = choices.GetProperty("posters").EnumerateArray().ToList();
        Assert.Equal(new[] { "/coco-alt.jpg", "/coco-default.jpg" }, listed.Select(p => p.GetProperty("path").GetString()!).ToArray());
        Assert.Equal("https://image.tmdb.org/t/p/w342/coco-alt.jpg", listed[0].GetProperty("url").GetString());
        Assert.Equal("en", listed[0].GetProperty("language").GetString());
        Assert.Equal(JsonValueKind.Null, listed[1].GetProperty("language").ValueKind);
        Assert.Equal(2000, listed[0].GetProperty("width").GetInt32());

        // Only a path from this title's own list.
        using (var foreign = await client.PutAsJsonAsync($"/api/media/items/{coco}/poster", new { tmdbPath = "/up-default.jpg" }, Ct))
        {
            Assert.Equal(HttpStatusCode.BadRequest, foreign.StatusCode);
            Assert.Contains("error", await foreign.Content.ReadAsStringAsync(Ct));
        }

        // Picked: beats the local file.
        detail = await OkJsonAsync(await client.PutAsJsonAsync($"/api/media/items/{coco}/poster", new { tmdbPath = "/coco-alt.jpg" }, Ct));
        Assert.Equal("chosen", Source(detail));
        var chosenUrl = PosterUrl(detail);
        Assert.NotEqual(localUrl, chosenUrl);
        Assert.Equal(_tmdb.Image("/coco-alt.jpg"), await PosterBytesAsync(client, coco));
        choices = await GetJsonAsync(client, $"/api/media/items/{coco}/posters");
        Assert.Equal("/coco-alt.jpg", choices.GetProperty("current").GetProperty("tmdbPath").GetString());

        // Something that isn't a picture is refused, and nothing changes.
        using (var text = await UploadAsync(client, coco, Encoding.UTF8.GetBytes("definitely not a poster"), "image/png"))
        {
            Assert.Equal(HttpStatusCode.BadRequest, text.StatusCode);
            Assert.Contains("error", await text.Content.ReadAsStringAsync(Ct));
        }
        Assert.Equal("chosen", Source(await GetJsonAsync(client, $"/api/media/items/{coco}")));

        // Uploaded: beats the pick. A tall PNG comes back as a JPEG at most 2000 px tall.
        detail = await OkJsonAsync(await UploadAsync(client, coco, Png(300, 3000, Green), "image/png"));
        Assert.Equal("custom", Source(detail));
        var customUrl = PosterUrl(detail);
        Assert.NotEqual(chosenUrl, customUrl);
        Assert.NotEqual(localUrl, customUrl);
        var custom = await PosterBytesAsync(client, coco);
        using (var image = Image.Load<Rgba32>(custom))
        {
            Assert.Equal("JPEG", image.Metadata.DecodedImageFormat?.Name);
            Assert.Equal(2000, image.Height);
            Assert.Equal(200, image.Width);
            var pixel = image[100, 1000];
            Assert.True(pixel.G > 150 && pixel.R < 80 && pixel.B < 80, $"expected green, got {pixel}");
        }
        // ?size= works on an upload like on any other art.
        using (var small = Image.Load<Rgba32>(await PosterBytesAsync(client, coco, "?size=200")))
            Assert.Equal(200, small.Height);
        var uploads = Directory.GetFiles(Path.Combine(_dataDirectory, "media-art", "custom"));
        Assert.Single(uploads);

        // A second upload replaces the first file rather than piling up.
        detail = await OkJsonAsync(await UploadAsync(client, coco, Png(200, 300, Red), "image/png"));
        Assert.NotEqual(customUrl, PosterUrl(detail));
        Assert.NotEqual(uploads[0], Assert.Single(Directory.GetFiles(Path.Combine(_dataDirectory, "media-art", "custom"))));

        // Reset: back to the local file, under the URL it had before, and the upload is gone.
        detail = await OkJsonAsync(await client.DeleteAsync($"/api/media/items/{coco}/poster", Ct));
        Assert.Equal("local", Source(detail));
        Assert.Equal(localUrl, PosterUrl(detail));
        Assert.Equal(seeded.CocoLocalPoster, await PosterBytesAsync(client, coco));
        Assert.Empty(Directory.GetFiles(Path.Combine(_dataDirectory, "media-art", "custom")));
    }

    [Fact]
    public async Task ARefreshOrARescan_KeepsTheChosenPoster()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var store = factory.Services.GetRequiredService<IMediaStore>();
        var seeded = await SeedAsync(store);

        await OkJsonAsync(await client.PutAsJsonAsync($"/api/media/items/{seeded.Up}/poster", new { tmdbPath = "/up-other.jpg" }, Ct));

        // TMDB's default poster changed since; a refresh takes the new default but keeps the pick.
        _tmdb.UpDefault = "/up-new-default.jpg";
        var detail = await OkJsonAsync(await client.PostAsJsonAsync($"/api/media/items/{seeded.Up}/refresh", new { }, Ct));
        Assert.Equal("chosen", Source(detail));
        var item = (await store.GetItemAsync(seeded.Up, Ct))!;
        Assert.Equal("/up-new-default.jpg", item.PosterRemote);
        Assert.Equal("/up-other.jpg", item.PosterChosen);
        Assert.Equal(_tmdb.Image("/up-other.jpg"), await PosterBytesAsync(client, seeded.Up));

        // A rescan of the files.
        var library = Assert.Single(await store.GetLibrariesAsync(Ct));
        await store.UpsertItemsAsync(MediaScanner.WalkMovies(library), Ct);
        Assert.Equal("/up-other.jpg", (await store.GetItemAsync(seeded.Up, Ct))!.PosterChosen);
        Assert.Equal("chosen", Source(await GetJsonAsync(client, $"/api/media/items/{seeded.Up}")));
    }

    // "Fix match" changed the TMDB poster path, but the cached copy was named after the item
    // alone, so the old film's poster went on being served for a day and then forever.
    [Fact]
    public async Task FixingAMatch_ServesTheNewTitlesPoster_NotTheOldDownload()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var seeded = await SeedAsync(factory.Services.GetRequiredService<IMediaStore>());

        var before = await GetJsonAsync(client, $"/api/media/items/{seeded.Up}");
        Assert.Equal("tmdb", Source(before));
        Assert.Equal(_tmdb.Image("/up-default.jpg"), await PosterBytesAsync(client, seeded.Up));

        var after = await OkJsonAsync(await client.PostAsJsonAsync($"/api/media/items/{seeded.Up}/match", new { tmdbId = 3 }, Ct));
        Assert.Equal("WALL-E", after.GetProperty("title").GetString());
        Assert.NotEqual(PosterUrl(before), PosterUrl(after));
        Assert.Equal(_tmdb.Image("/wall-e.jpg"), await PosterBytesAsync(client, seeded.Up));
        // The old title's copy was cleared away when the new one arrived.
        var copies = Directory.GetFiles(Path.Combine(_dataDirectory, "media-art"), $"{seeded.Up:N}-poster*");
        Assert.Single(copies);
    }

    [Fact]
    public async Task FindMissingPosters_QueuesOnlyTitlesWithoutAnyPoster_AndLooksThemUp()
    {
        using var factory = CreateFactory();
        using var client = factory.CreateClient();
        var store = factory.Services.GetRequiredService<IMediaStore>();
        var seeded = await SeedAsync(store);

        var queued = await OkJsonAsync(await client.PostAsync("/api/media/artwork/refresh-missing", null, Ct));
        Assert.Equal(1, queued.GetProperty("queued").GetInt32());

        // "Nothing" is searched for again straight away (not a week later) - TMDB finds it this time.
        var deadline = DateTime.UtcNow.AddSeconds(30);
        MediaItem? nothing = null;
        while (DateTime.UtcNow < deadline)
        {
            nothing = await store.GetItemAsync(seeded.Nothing, Ct);
            if (nothing?.TmdbId is not null && !(await GetJsonAsync(client, "/api/media/status")).GetProperty("scanning").GetBoolean()) break;
            await Task.Delay(100, Ct);
        }
        Assert.Equal(4, nothing?.TmdbId);
        Assert.Equal("tmdb", Source(await GetJsonAsync(client, $"/api/media/items/{seeded.Nothing}")));
        Assert.Contains("/3/search/movie", _tmdb.Requests);

        // Now every title has a poster.
        queued = await OkJsonAsync(await client.PostAsync("/api/media/artwork/refresh-missing", null, Ct));
        Assert.Equal(0, queued.GetProperty("queued").GetInt32());
    }

    // MARK: - The store and the view

    private static MediaItem Item(Guid library, string kind, string title, Guid? parent = null) => new()
    {
        Id = Guid.NewGuid(),
        LibraryId = library,
        Kind = kind,
        ParentId = parent,
        Title = title,
        SortTitle = title,
        Path = $"/films/{title}",
        AddedAt = DateTimeOffset.UtcNow
    };

    [Fact]
    public async Task TheStore_KeepsTheOverride_ThroughARescanAndAStaleMetadataWrite()
    {
        using var store = new SqliteMediaStore(_dataDirectory);
        var library = Guid.NewGuid();
        var coco = Item(library, MediaKinds.Movie, "Coco");
        await store.UpsertItemsAsync([coco], Ct);
        var stale = (await store.GetItemAsync(coco.Id, Ct))!;

        await store.SetPosterOverrideAsync(coco.Id, "/data/media-art/custom/x.jpg", "/picked.jpg", Ct);

        // A rescan (the files know nothing of it) and a metadata write from an item read before it.
        var rescanned = Item(library, MediaKinds.Movie, "Coco");
        rescanned.Id = coco.Id;
        rescanned.PosterLocal = "/films/Coco/poster.jpg";
        await store.UpsertItemsAsync([rescanned], Ct);
        Assert.Equal("/films/Coco/poster.jpg", (await store.GetItemAsync(coco.Id, Ct))!.PosterLocal);
        stale.PosterLocal = rescanned.PosterLocal;
        stale.TmdbId = 354912;
        stale.PosterRemote = "/default.jpg";
        stale.MetadataFetchedAt = DateTimeOffset.UtcNow;
        await store.UpdateMetadataAsync(stale, Ct);

        var stored = (await store.GetItemAsync(coco.Id, Ct))!;
        Assert.Equal("/data/media-art/custom/x.jpg", stored.PosterCustom);
        Assert.Equal("/picked.jpg", stored.PosterChosen);
        Assert.Equal("/films/Coco/poster.jpg", stored.PosterLocal);
        Assert.Equal("/default.jpg", stored.PosterRemote);
        Assert.Equal(MediaPosterSources.Custom, stored.PosterSource);

        await store.SetPosterOverrideAsync(coco.Id, null, null, Ct);
        Assert.Equal(MediaPosterSources.Local, (await store.GetItemAsync(coco.Id, Ct))!.PosterSource);
    }

    [Fact]
    public async Task QueueingTitlesWithoutPosters_TakesOnlyUnlockedMoviesAndShowsWithNoPosterAtAll()
    {
        using var store = new SqliteMediaStore(_dataDirectory);
        var library = Guid.NewGuid();
        var withRemote = Item(library, MediaKinds.Movie, "Remote");
        var withLocal = Item(library, MediaKinds.Movie, "Local");
        withLocal.PosterLocal = "/films/Local/poster.jpg";
        var withCustom = Item(library, MediaKinds.Movie, "Custom");
        var matchedBare = Item(library, MediaKinds.Movie, "Matched");
        var unmatchedBare = Item(library, MediaKinds.Movie, "Unmatched");
        var locked = Item(library, MediaKinds.Movie, "Locked");
        var show = Item(library, MediaKinds.Show, "Show");
        var episode = Item(library, MediaKinds.Episode, "Pilot", show.Id);
        var all = new[] { withRemote, withLocal, withCustom, matchedBare, unmatchedBare, locked, show, episode };
        await store.UpsertItemsAsync(all, Ct);
        foreach (var item in all)
        {
            item.MetadataFetchedAt = DateTimeOffset.UtcNow;
            if (item != unmatchedBare) item.TmdbId = 100;
            if (item == withRemote) item.PosterRemote = "/remote.jpg";
            if (item == locked) item.MetadataLocked = true;
            await store.UpdateMetadataAsync(item, Ct);
        }
        await store.SetPosterOverrideAsync(withCustom.Id, "/data/media-art/custom/c.jpg", null, Ct);
        Assert.Empty(await store.ItemsNeedingMetadataAsync(DateTimeOffset.UtcNow.AddDays(-7), 50, Ct));

        Assert.Equal(3, await store.QueueTitlesWithoutPostersAsync(Ct));

        var queued = (await store.ItemsNeedingMetadataAsync(DateTimeOffset.UtcNow.AddDays(-7), 50, Ct)).Select(i => i.Id).ToHashSet();
        Assert.Equal(new HashSet<Guid> { matchedBare.Id, unmatchedBare.Id, show.Id }, queued);
        // A matched one keeps its match on the way back through.
        Assert.Equal(100, (await store.GetItemAsync(matchedBare.Id, Ct))!.TmdbId);
    }

    [Fact]
    public void ThePosterSource_FollowsThePrecedence()
    {
        var item = new MediaItem();
        Assert.Equal(MediaPosterSources.None, item.PosterSource);
        Assert.False(item.HasPoster);
        item.PosterRemote = "/default.jpg";
        Assert.Equal(MediaPosterSources.Tmdb, item.PosterSource);
        item.PosterLocal = "/films/Coco/folder.jpg";
        Assert.Equal(MediaPosterSources.Local, item.PosterSource);
        item.PosterChosen = "/picked.jpg";
        Assert.Equal(MediaPosterSources.Chosen, item.PosterSource);
        item.PosterCustom = "/data/media-art/custom/c.jpg";
        Assert.Equal(MediaPosterSources.Custom, item.PosterSource);
    }

    [Fact]
    public void TheArtUrlVersion_ChangesWhenTheCoverChanges()
    {
        var item = new MediaItem { Id = Guid.NewGuid(), Kind = MediaKinds.Movie, PosterRemote = "/default.jpg" };
        var urls = new List<string?> { MediaEndpoints.MediaView.ArtUrl(item, "poster") };
        item.PosterLocal = "/films/Coco/folder.jpg";
        urls.Add(MediaEndpoints.MediaView.ArtUrl(item, "poster"));
        item.PosterChosen = "/picked.jpg";
        urls.Add(MediaEndpoints.MediaView.ArtUrl(item, "poster"));
        item.PosterCustom = "/data/media-art/custom/one.jpg";
        urls.Add(MediaEndpoints.MediaView.ArtUrl(item, "poster"));
        item.PosterCustom = "/data/media-art/custom/two.jpg";
        urls.Add(MediaEndpoints.MediaView.ArtUrl(item, "poster"));
        Assert.All(urls, url => Assert.StartsWith($"/api/media/items/{item.Id}/poster?v=", url));
        Assert.Equal(urls.Count, urls.Distinct().Count());

        // Back to automatic is back to the URL it had.
        item.PosterCustom = null;
        item.PosterChosen = null;
        Assert.Equal(urls[1], MediaEndpoints.MediaView.ArtUrl(item, "poster"));
    }

    [Fact]
    public async Task Episodes_ShowTheirShowsCustomPoster()
    {
        using var store = new SqliteMediaStore(_dataDirectory);
        var library = Guid.NewGuid();
        var show = Item(library, MediaKinds.Show, "Bluey");
        show.PosterRemote = "/bluey.jpg";
        var episode = Item(library, MediaKinds.Episode, "Magic Xylophone", show.Id);
        episode.SeasonNumber = 1;
        episode.EpisodeNumber = 1;
        await store.UpsertItemsAsync([show, episode], Ct);
        await store.UpdateMetadataAsync(show, Ct);
        var automatic = (await MediaEndpoints.MediaView.LoadAsync(store, "", Ct)).Summary(episode).PosterUrl;

        await store.SetPosterOverrideAsync(show.Id, "/data/media-art/custom/bluey.jpg", null, Ct);

        var view = await MediaEndpoints.MediaView.LoadAsync(store, "", Ct);
        var showPoster = view.Summary(view.Find(show.Id)!).PosterUrl;
        Assert.NotEqual(automatic, showPoster);
        Assert.Equal(showPoster, view.Summary(view.Find(episode.Id)!).PosterUrl);
    }

    [Fact]
    public void AnUpload_MustBeAJpegPngOrWebp()
    {
        Assert.NotNull(MediaCustomPoster.ToJpeg(Encoding.UTF8.GetBytes("<html>not an image</html>")).Error);
        Assert.NotNull(MediaCustomPoster.ToJpeg([]).Error);
        using (var gif = new Image<Rgba32>(10, 10, Red))
        using (var stream = new MemoryStream())
        {
            gif.SaveAsGif(stream);
            Assert.NotNull(MediaCustomPoster.ToJpeg(stream.ToArray()).Error);
        }
        var (jpeg, error) = MediaCustomPoster.ToJpeg(Png(40, 60, Red));
        Assert.Null(error);
        using var image = Image.Load<Rgba32>(jpeg!);
        Assert.Equal("JPEG", image.Metadata.DecodedImageFormat?.Name);
        Assert.Equal((40, 60), (image.Width, image.Height));
    }

    // MARK: - TMDB

    // Movies 1 (Coco), 2 (Up), 3 (WALL-E) and 4 (Nothing, found only by search), and a picture for
    // every poster path, each a different colour so the test can tell which one was served.
    private sealed class FakeTmdb : HttpMessageHandler
    {
        public string UpDefault { get; set; } = "/up-default.jpg";

        public List<string> Requests { get; } = [];

        private readonly Dictionary<string, byte[]> _images = [];

        public byte[] Image(string path)
        {
            lock (_images)
            {
                if (_images.TryGetValue(path, out var known)) return known;
                var hash = path.Aggregate(17, (h, c) => h * 31 + c);
                return _images[path] = Png(3, 5, new Rgba32((byte)hash, (byte)(hash >> 8), (byte)(hash >> 16)));
            }
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var uri = request.RequestUri!;
            lock (Requests) Requests.Add(uri.AbsolutePath);
            if (uri.Host == "image.tmdb.org")
            {
                // /t/p/w500/coco-alt.jpg
                var path = uri.AbsolutePath[uri.AbsolutePath.IndexOf('/', "/t/p/".Length)..];
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Image(path)) });
            }
            var json = uri.AbsolutePath switch
            {
                "/3/movie/1" => Movie(1, "Coco", "2017-10-27", "/coco-default.jpg"),
                "/3/movie/2" => Movie(2, "Up", "2009-05-29", UpDefault),
                "/3/movie/3" => Movie(3, "WALL-E", "2008-06-27", "/wall-e.jpg"),
                "/3/movie/4" => Movie(4, "Nothing", "2003-01-01", "/nothing.jpg"),
                "/3/movie/1/images" => """
                    { "id": 1, "posters": [
                      { "file_path": "/coco-default.jpg", "width": 1000, "height": 1500, "iso_639_1": null, "vote_average": 5.2 },
                      { "file_path": "/coco-alt.jpg", "width": 2000, "height": 3000, "iso_639_1": "en", "vote_average": 5.6 } ] }
                    """,
                "/3/movie/2/images" => """
                    { "id": 2, "posters": [
                      { "file_path": "/up-default.jpg", "width": 1000, "height": 1500, "iso_639_1": "en", "vote_average": 5.5 },
                      { "file_path": "/up-other.jpg", "width": 1000, "height": 1500, "iso_639_1": "en", "vote_average": 5.1 } ] }
                    """,
                "/3/search/movie" => System.Web.HttpUtility.ParseQueryString(uri.Query)["query"] switch
                {
                    "Coco" => """{ "results": [ { "id": 1, "title": "Coco", "release_date": "2017-10-27" } ] }""",
                    "Up" => """{ "results": [ { "id": 2, "title": "Up", "release_date": "2009-05-29" } ] }""",
                    "Nothing" => """{ "results": [ { "id": 4, "title": "Nothing", "release_date": "2003-01-01" } ] }""",
                    _ => """{ "results": [] }"""
                },
                _ => null
            };
            return Task.FromResult(json is null
                ? new HttpResponseMessage(HttpStatusCode.NotFound)
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") });
        }

        private static string Movie(int id, string title, string released, string poster) => JsonSerializer.Serialize(new
        {
            id,
            title,
            release_date = released,
            overview = $"{title}, the film.",
            poster_path = poster,
            backdrop_path = (string?)null,
            genres = new[] { new { id = 16, name = "Animation" } }
        });
    }
}
