using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats.Gif;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Processing;

namespace ReelHouse;

// Smaller copies of artwork for the art endpoints' ?size=, made once and kept in one folder.
// Used for music, film/TV and podcast art alike.
//
// A copy is always a plain (baseline) JPEG. Roku can't draw progressive JPEGs, and a good share
// of TMDB posters and podcast covers are progressive, so a progressive original gets a new copy
// even when it is already small enough. Browsers and the phone apps draw either kind.
public sealed class SizedArtCache(string root)
{
    // The sizes a ?size= is rounded up to, so the cache holds a handful of copies per picture
    // rather than one per pixel width some client happened to ask for.
    private static readonly int[] Buckets = [64, 128, 200, 300, 400, 600, 800, 1200];

    public string Root { get; } = root;

    public static int Bucket(int size)
    {
        var clamped = Math.Clamp(size, 64, 1200);
        return Buckets.First(b => b >= clamped);
    }

    // A copy no wider or taller than `size`. The original when it is already that small and in a
    // format every client draws, or when it cannot be decoded (the client still gets a picture).
    public async Task<string> SizedAsync(string original, IMediaFileSystem fs, int size, CancellationToken cancellationToken)
    {
        var bucket = Bucket(size);
        var entry = fs.Stat(original);
        if (entry is null) return original;
        var stamp = $"{original}|{entry.Length}|{entry.ModifiedUtc.Ticks}";
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(stamp)).AsSpan(0, 10)).ToLowerInvariant();
        var sized = Path.Combine(Root, $"{hash}-{bucket}.jpg");
        if (File.Exists(sized)) return sized;
        try
        {
            await using var stream = fs.OpenRead(original);
            using var image = await Image.LoadAsync(SafeImageDecoding.Options, stream, cancellationToken);
            var fits = image.Width <= bucket && image.Height <= bucket;
            if (fits && DrawnEverywhere(image)) return original;
            if (!fits) image.Mutate(context => context.Resize(new ResizeOptions { Size = new Size(bucket, bucket), Mode = ResizeMode.Max }));
            Directory.CreateDirectory(Root);
            // A temporary name of its own: an album page asks for the same new size several times
            // at once (every track row shows the cover), and two requests writing one shared .tmp
            // collided ("being used by another process" -> 500).
            var temporary = $"{sized}.{Guid.NewGuid():N}.tmp";
            try
            {
                await image.SaveAsJpegAsync(temporary, new JpegEncoder { Quality = 85 }, cancellationToken);
                if (!File.Exists(sized)) File.Move(temporary, sized, overwrite: true);
            }
            finally
            {
                try { File.Delete(temporary); } catch (IOException) { }
            }
            return File.Exists(sized) ? sized : original;
        }
        catch (Exception ex) when (ex is ImageFormatException or UnknownImageFormatException or InvalidImageContentException or IOException or NotSupportedException)
        {
            return original;
        }
    }

    // Baseline JPEG, PNG and GIF: what every ReelHouse client, Roku included, can draw.
    private static bool DrawnEverywhere(Image image) => image.Metadata.DecodedImageFormat switch
    {
        JpegFormat => image.Metadata.GetJpegMetadata().Progressive != true,
        PngFormat or GifFormat => true,
        _ => false
    };
}
