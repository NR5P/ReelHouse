using Microsoft.Data.Sqlite;
using ReelHouse;
using Xunit;

namespace ReelHouse.Tests;

// A rescan rebuilds each item from the files, which only know about local artwork. It used to
// replace the stored artwork wholesale, so every TMDB poster and backdrop vanished on the next
// scan (blank tiles on every client for films without a folder.jpg).
public sealed class MediaRemoteArtworkTests : IDisposable
{
    private readonly string _dataDirectory = Path.Combine(Path.GetTempPath(), $"media-remote-art-{Guid.NewGuid():N}");

    public MediaRemoteArtworkTests() => Directory.CreateDirectory(_dataDirectory);

    public void Dispose()
    {
        try { TempDirectories.Delete(_dataDirectory); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static readonly Guid Library = Guid.NewGuid();

    // What a scan of the files produces.
    private static MediaItem Scanned(Guid id, string title, string? localPoster = null) => new()
    {
        Id = id,
        LibraryId = Library,
        Kind = MediaKinds.Movie,
        Title = title,
        SortTitle = title,
        Path = $"/films/{title}.mkv",
        AddedAt = DateTimeOffset.UtcNow,
        PosterLocal = localPoster
    };

    private static async Task MatchAsync(SqliteMediaStore store, MediaItem item, int tmdbId)
    {
        item.TmdbId = tmdbId;
        item.MetadataFetchedAt = DateTimeOffset.UtcNow;
        item.PosterRemote = $"/poster-{tmdbId}.jpg";
        item.BackdropRemote = $"/backdrop-{tmdbId}.jpg";
        await store.UpdateMetadataAsync(item, Ct);
    }

    [Fact]
    public async Task ARescan_KeepsTheTmdbArtwork_AndTakesTheLocalArtworkFromTheFiles()
    {
        using var store = new SqliteMediaStore(_dataDirectory);
        var id = Guid.NewGuid();
        var coco = Scanned(id, "Coco");
        await store.UpsertItemsAsync([coco], Ct);
        await MatchAsync(store, coco, 354912);

        await store.UpsertItemsAsync([Scanned(id, "Coco", localPoster: "/films/Coco-poster.jpg")], Ct);

        var stored = (await store.GetItemAsync(id, Ct))!;
        Assert.Equal("/poster-354912.jpg", stored.PosterRemote);
        Assert.Equal("/backdrop-354912.jpg", stored.BackdropRemote);
        Assert.Equal("/films/Coco-poster.jpg", stored.PosterLocal);
        Assert.Empty(await store.ItemsNeedingMetadataAsync(DateTimeOffset.UtcNow.AddDays(-7), 10, Ct));
    }

    [Fact]
    public async Task AnOlderLibrary_SendsMatchedTitlesThatLostTheirArtwork_BackForMetadata_Once()
    {
        var lost = Guid.NewGuid();
        var kept = Guid.NewGuid();
        var unmatched = Guid.NewGuid();
        using (var store = new SqliteMediaStore(_dataDirectory))
        {
            await store.UpsertItemsAsync([Scanned(lost, "Coco"), Scanned(kept, "Up"), Scanned(unmatched, "Home Video")], Ct);
            await MatchAsync(store, (await store.GetItemAsync(kept, Ct))!, 14160);
            var coco = (await store.GetItemAsync(lost, Ct))!;
            coco.TmdbId = 354912;
            coco.MetadataFetchedAt = DateTimeOffset.UtcNow;
            await store.UpdateMetadataAsync(coco, Ct);
            var home = (await store.GetItemAsync(unmatched, Ct))!;
            home.MetadataFetchedAt = DateTimeOffset.UtcNow;
            await store.UpdateMetadataAsync(home, Ct);
        }
        // A media.db from before the repair.
        using (var connection = new SqliteConnection($"Data Source={Path.Combine(_dataDirectory, "media.db")};Pooling=False"))
        {
            connection.Open();
            using var forget = connection.CreateCommand();
            forget.CommandText = "DELETE FROM MediaState WHERE Key = 'artwork.remoteRestored'";
            forget.ExecuteNonQuery();
        }

        using (var store = new SqliteMediaStore(_dataDirectory))
        {
            var queued = await store.ItemsNeedingMetadataAsync(DateTimeOffset.UtcNow.AddDays(-7), 10, Ct);
            var item = Assert.Single(queued);
            Assert.Equal(lost, item.Id);
            Assert.Equal(354912, item.TmdbId);
            await MatchAsync(store, item, 354912);
        }

        using (var store = new SqliteMediaStore(_dataDirectory))
            Assert.Empty(await store.ItemsNeedingMetadataAsync(DateTimeOffset.UtcNow.AddDays(-7), 10, Ct));
    }
}
