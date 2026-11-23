using ReelHouse;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.PixelFormats;
using Xunit;

namespace ReelHouse.Tests;

public sealed class MusicArtCacheTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"music-art-{Guid.NewGuid():N}");

    private const string ProgressiveJpeg40x60 =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/" +
        "2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wgARCAA8ACgDASIAAhEBAxEB/8QA" +
        "FQABAQAAAAAAAAAAAAAAAAAAAAb/xAAWAQEBAQAAAAAAAAAAAAAAAAAABAX/2gAMAwEAAhADEAAAAZ8bM4AAAAAAAAAAH//EABQQAQAAAAAAAAAAAAAAAAAA" +
        "AFD/2gAIAQEAAQUCI//EABQRAQAAAAAAAAAAAAAAAAAAADD/2gAIAQMBAT8BT//EABQRAQAAAAAAAAAAAAAAAAAAADD/2gAIAQIBAT8BT//EABQQAQAAAAAA" +
        "AAAAAAAAAAAAAFD/2gAIAQEABj8CI//EABQQAQAAAAAAAAAAAAAAAAAAAFD/2gAIAQEAAT8hI//aAAwDAQACAAMAAAAQAAAAAAAAAAAA/8QAFBEBAAAAAAAA" +
        "AAAAAAAAAAAAMP/aAAgBAwEBPxBP/8QAFBEBAAAAAAAAAAAAAAAAAAAAMP/aAAgBAgEBPxBP/8QAFBABAAAAAAAAAAAAAAAAAAAAUP/aAAgBAQABPxAj/9k=";

    public void Dispose()
    {
        try { TempDirectories.Delete(_root); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    // An album page asks for the same new size once per track row, all at once. They used to share
    // one temporary file and fail with "being used by another process" (a 500 on the Apple TV).
    [Fact]
    public async Task ManyRequestsForTheSameNewSize_AllGetAPicture()
    {
        Directory.CreateDirectory(_root);
        var cover = Path.Combine(_root, "cover.jpg");
        using (var image = new Image<Rgb24>(900, 900, new Rgb24(200, 120, 40))) await image.SaveAsJpegAsync(cover, TestContext.Current.CancellationToken);
        var cache = new MusicArtCache(Path.Combine(_root, "cache"));

        var results = await Task.WhenAll(Enumerable.Range(0, 16).Select(_ =>
            Task.Run(() => cache.SizedAsync(cover, LocalMediaFileSystem.Instance, 128, TestContext.Current.CancellationToken))));

        Assert.All(results, path => Assert.True(File.Exists(path), path));
        var sized = Assert.Single(results.Distinct(), p => p != cover);
        using var resized = await Image.LoadAsync(sized, TestContext.Current.CancellationToken);
        Assert.Equal(128, resized.Width);
        Assert.Empty(Directory.EnumerateFiles(cache.SizedRoot, "*.tmp"));
    }

    // Roku can't draw progressive JPEGs (many TMDB posters and podcast covers are), so a sized copy
    // is always baseline - even when the original is already small enough.
    [Fact]
    public async Task ASmallProgressiveJpeg_GetsABaselineCopy()
    {
        Directory.CreateDirectory(_root);
        var ct = TestContext.Current.CancellationToken;
        var poster = Path.Combine(_root, "poster.jpg");
        // ImageSharp can't write a progressive JPEG, so this is a 40x60 one made elsewhere.
        await File.WriteAllBytesAsync(poster, Convert.FromBase64String(ProgressiveJpeg40x60), ct);
        using (var original = await Image.LoadAsync(poster, ct)) Assert.True(original.Metadata.GetJpegMetadata().Progressive);
        var cache = new SizedArtCache(Path.Combine(_root, "sized"));

        var sized = await cache.SizedAsync(poster, LocalMediaFileSystem.Instance, 400, ct);

        Assert.NotEqual(poster, sized);
        using var copy = await Image.LoadAsync(sized, ct);
        Assert.NotEqual(true, copy.Metadata.GetJpegMetadata().Progressive);
        Assert.Equal(40, copy.Width);
    }

    [Fact]
    public async Task ASmallBaselineJpeg_IsServedAsItIs()
    {
        Directory.CreateDirectory(_root);
        var ct = TestContext.Current.CancellationToken;
        var poster = Path.Combine(_root, "poster.jpg");
        using (var image = new Image<Rgb24>(300, 450, new Rgb24(20, 40, 160))) await image.SaveAsJpegAsync(poster, ct);
        var cache = new SizedArtCache(Path.Combine(_root, "sized"));

        Assert.Equal(poster, await cache.SizedAsync(poster, LocalMediaFileSystem.Instance, 600, ct));
    }
}
