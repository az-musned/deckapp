using SkiaSharp;

namespace DeckWindowsAgent.Screen;

public static class ScreenFrameEncoder
{
    public static byte[] EncodeJpeg(in CapturedFrame frame, int maxWidth, int jpegQuality)
    {
        var info = new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var image = SKImage.FromPixelCopy(info, frame.Bgra, frame.Stride);

        SKImage? scaledImage = null;
        var source = image;
        if (frame.Width > maxWidth)
        {
            var scale = maxWidth / (double)frame.Width;
            var targetHeight = Math.Max(1, (int)Math.Round(frame.Height * scale));
            using var bitmap = SKBitmap.FromImage(image);
            var resized = bitmap.Resize(new SKImageInfo(maxWidth, targetHeight, SKColorType.Bgra8888, SKAlphaType.Premul), SKSamplingOptions.Default);
            if (resized is not null)
            {
                using (resized)
                {
                    scaledImage = SKImage.FromBitmap(resized);
                }
                source = scaledImage;
            }
        }

        try
        {
            using var data = source.Encode(SKEncodedImageFormat.Jpeg, jpegQuality);
            return data.ToArray();
        }
        finally
        {
            scaledImage?.Dispose();
        }
    }
}
