using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Formats.Webp;
using SixLabors.ImageSharp.Processing;

namespace ReelHouse;

// A poster an admin uploads for a movie or show (POST /api/media/items/{id}/poster). Whatever
// arrives is decoded (which is the check that it is a picture at all) and saved again as a plain
// JPEG of a sensible size, so every client, Roku included, can draw it and nobody is sent a
// 40-megapixel phone photo for a shelf tile.
public static class MediaCustomPoster
{
    public const long MaxUploadBytes = 15 * 1024 * 1024;
    public const int MaxEdge = 2000;
    // Checked before decoding: a small file can still claim enormous dimensions.
    private const long MaxPixels = 60_000_000;

    public static (byte[]? Jpeg, string? Error) ToJpeg(byte[] upload)
    {
        if (upload.Length == 0) return (null, "Send the image file as the request body.");
        try
        {
            var info = Image.Identify(SafeImageDecoding.Options, upload);
            if (info.Metadata.DecodedImageFormat is not (JpegFormat or PngFormat or WebpFormat))
                return (null, "Use a JPEG, PNG or WebP image.");
            if ((long)info.Width * info.Height > MaxPixels || info.Width <= 0 || info.Height <= 0)
                return (null, "That image is too large. Use one under 60 megapixels.");

            using var image = Image.Load(SafeImageDecoding.Options, upload);
            image.Mutate(context =>
            {
                // A phone photo stores "rotate me" separately from the pixels.
                context.AutoOrient();
                if (image.Width > MaxEdge || image.Height > MaxEdge)
                    context.Resize(new ResizeOptions { Size = new Size(MaxEdge, MaxEdge), Mode = ResizeMode.Max });
                // JPEG has no transparency; a cut-out PNG sits on the dark shelf colour.
                context.BackgroundColor(Color.Black);
            });
            image.Metadata.ExifProfile = null;
            image.Metadata.XmpProfile = null;
            using var output = new MemoryStream();
            image.SaveAsJpeg(output, new JpegEncoder { Quality = 88 });
            return (output.ToArray(), null);
        }
        catch (Exception ex) when (ex is UnknownImageFormatException or InvalidImageContentException or ImageFormatException or NotSupportedException)
        {
            return (null, "That file isn't an image this server can read. Use a JPEG, PNG or WebP image.");
        }
    }
}
