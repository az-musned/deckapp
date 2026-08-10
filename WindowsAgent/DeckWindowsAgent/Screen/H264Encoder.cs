using System.Runtime.InteropServices;
using SharpGen.Runtime;
using SkiaSharp;
using Vortice.MediaFoundation;

namespace DeckWindowsAgent.Screen;

public readonly record struct EncodedFrame(bool IsKeyframe, byte[] AnnexB);

/// Wraps a Media Foundation H.264 encoder MFT. One instance per active capture session --
/// recreate (dispose + construct a new one) to force the next output to start with a fresh
/// keyframe, since a newly-initialized encoder's first output sample is always an IDR with
/// leading SPS/PPS (verified against this machine's encoder MFT during development).
public sealed class H264Encoder : IDisposable
{
    private const uint MFNotAcceptingHResult = 0xC00D6D72;

    private readonly IMFTransform _transform;
    private readonly int _width;
    private readonly int _height;
    private long _sampleTime;
    private readonly long _sampleDuration;
    private bool _disposed;

    public H264Encoder(int width, int height, int fps, int bitrateBps)
    {
        _width = width;
        _height = height;
        _sampleDuration = 10_000_000L / Math.Max(1, fps);

        MediaFactory.MFStartup();

        using var activates = MediaFactory.MFTEnumEx(
            TransformCategoryGuids.VideoEncoder,
            0,
            null,
            new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = VideoFormatGuids.H264 });

        IMFActivate? chosen = null;
        foreach (var activate in activates) { chosen = activate; break; }
        if (chosen is null) throw new InvalidOperationException("No H.264 encoder MFT is available on this system.");

        _transform = chosen.ActivateObject<IMFTransform>();

        var frameSize = PackDimensions(width, height);
        var frameRate = PackDimensions(fps, 1);

        var outputType = MediaFactory.MFCreateMediaType();
        var outAttributes = outputType.QueryInterface<IMFAttributes>();
        outAttributes.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        outAttributes.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.H264);
        outAttributes.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)bitrateBps);
        outAttributes.Set(MediaTypeAttributeKeys.FrameSize, frameSize);
        outAttributes.Set(MediaTypeAttributeKeys.FrameRate, frameRate);
        outAttributes.Set(MediaTypeAttributeKeys.InterlaceMode, 2u); // MFVideoInterlace_Progressive
        _transform.SetOutputType(0, outputType, 0);

        var inputType = MediaFactory.MFCreateMediaType();
        var inAttributes = inputType.QueryInterface<IMFAttributes>();
        inAttributes.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
        inAttributes.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.NV12);
        inAttributes.Set(MediaTypeAttributeKeys.FrameSize, frameSize);
        inAttributes.Set(MediaTypeAttributeKeys.FrameRate, frameRate);
        inAttributes.Set(MediaTypeAttributeKeys.InterlaceMode, 2u);
        _transform.SetInputType(0, inputType, 0);

        _transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, 0);
        _transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, 0);
    }

    public EncodedFrame? Encode(in CapturedFrame frame)
    {
        var nv12 = BgraToNv12(frame, _width, _height);

        using var buffer = MediaFactory.MFCreateMemoryBuffer(nv12.Length);
        buffer.Lock(out var destination, out _, out _);
        Marshal.Copy(nv12, 0, destination, nv12.Length);
        buffer.Unlock();
        buffer.CurrentLength = nv12.Length;

        using var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = _sampleTime;
        sample.SampleDuration = _sampleDuration;
        _sampleTime += _sampleDuration;

        var drained = new List<byte>();
        var sawKeyframe = false;

        var accepted = false;
        while (!accepted)
        {
            try
            {
                _transform.ProcessInput(0, sample, 0);
                accepted = true;
            }
            catch (SharpGenException error) when (unchecked((uint)error.ResultCode.Code) == MFNotAcceptingHResult)
            {
                DrainOutput(drained, ref sawKeyframe);
            }
        }
        DrainOutput(drained, ref sawKeyframe);

        return drained.Count == 0 ? null : new EncodedFrame(sawKeyframe, drained.ToArray());
    }

    private void DrainOutput(List<byte> sink, ref bool sawKeyframe)
    {
        while (true)
        {
            var outputInfo = _transform.GetOutputStreamInfo(0);
            using var outputBuffer = MediaFactory.MFCreateMemoryBuffer(Math.Max(outputInfo.Size, 1));
            using var outputSample = MediaFactory.MFCreateSample();
            outputSample.AddBuffer(outputBuffer);
            var dataBuffer = new OutputDataBuffer { StreamID = 0, Sample = outputSample };

            var result = _transform.ProcessOutput(ProcessOutputFlags.None, 1, ref dataBuffer, out _);
            // Deliberately not disposing dataBuffer.Sample separately from outputSample here:
            // reading it back off the struct constructs a fresh SharpGen wrapper around the
            // same underlying COM object, and disposing that second wrapper throws off the
            // reference count in a way that leaks native memory (~3-4MB/frame, confirmed by
            // isolated testing) rather than double-freeing. outputSample's own disposal is
            // sufficient for this MFT, which fills the sample we provide rather than
            // allocating its own (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES not set).
            if (result.Failure) return;

            using var contiguous = dataBuffer.Sample.ConvertToContiguousBuffer();
            contiguous.Lock(out var source, out _, out var currentLength);
            var chunk = new byte[currentLength];
            Marshal.Copy(source, chunk, 0, currentLength);
            contiguous.Unlock();

            if (ContainsIdrSlice(chunk)) sawKeyframe = true;
            sink.AddRange(chunk);
        }
    }

    private static bool ContainsIdrSlice(byte[] annexB)
    {
        for (var i = 0; i + 4 < annexB.Length; i++)
        {
            if (annexB[i] != 0 || annexB[i + 1] != 0 || annexB[i + 2] != 0 || annexB[i + 3] != 1) continue;
            if ((annexB[i + 4] & 0x1F) == 5) return true;
        }
        return false;
    }

    private static ulong PackDimensions(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

    private static byte[] BgraToNv12(in CapturedFrame frame, int targetWidth, int targetHeight)
    {
        byte[] source;
        int sourceStride;

        if (frame.Width == targetWidth && frame.Height == targetHeight)
        {
            source = frame.Bgra;
            sourceStride = frame.Stride;
        }
        else
        {
            // Scale natively via Skia rather than nearest-index sampling into the original
            // buffer -- sampling with clamped source indices only ever reads the top-left
            // region when downscaling, which crops the image instead of resizing it.
            var sourceInfo = new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
            using var sourceImage = SKImage.FromPixelCopy(sourceInfo, frame.Bgra, frame.Stride);
            using var sourceBitmap = SKBitmap.FromImage(sourceImage);
            using var resized = sourceBitmap.Resize(
                new SKImageInfo(targetWidth, targetHeight, SKColorType.Bgra8888, SKAlphaType.Premul),
                SKSamplingOptions.Default);
            if (resized is null) return new byte[targetWidth * targetHeight * 3 / 2];
            source = resized.Bytes;
            sourceStride = resized.RowBytes;
        }

        var ySize = targetWidth * targetHeight;
        var nv12 = new byte[ySize + ySize / 2];
        var uvWidth = targetWidth / 2;
        var uvOffset = ySize;

        Parallel.For(0, targetHeight / 2, uvRow =>
        {
            var y0 = uvRow * 2;
            var y1 = y0 + 1;
            var yRow0Offset = y0 * targetWidth;
            var yRow1Offset = y1 * targetWidth;
            var sourceRow0 = y0 * sourceStride;
            var sourceRow1 = y1 * sourceStride;

            for (var x = 0; x < targetWidth; x++)
            {
                var sourceColumn = x * 4;
                WriteLuma(source, sourceRow0 + sourceColumn, nv12, yRow0Offset + x);
                WriteLuma(source, sourceRow1 + sourceColumn, nv12, yRow1Offset + x);
            }

            for (var uvX = 0; uvX < uvWidth; uvX++)
            {
                var offset = sourceRow0 + uvX * 2 * 4;
                if (offset + 2 >= source.Length) continue;
                int b = source[offset], g = source[offset + 1], r = source[offset + 2];
                var u = (byte)Math.Clamp((-38 * r - 74 * g + 112 * b + 128 * 256) >> 8, 0, 255);
                var v = (byte)Math.Clamp((112 * r - 94 * g - 18 * b + 128 * 256) >> 8, 0, 255);
                var pairIndex = uvOffset + (uvRow * uvWidth + uvX) * 2;
                nv12[pairIndex] = u;
                nv12[pairIndex + 1] = v;
            }
        });

        return nv12;

        static void WriteLuma(byte[] source, int offset, byte[] destination, int destinationIndex)
        {
            if (offset + 2 >= source.Length) return;
            int b = source[offset], g = source[offset + 1], r = source[offset + 2];
            destination[destinationIndex] = (byte)Math.Clamp((66 * r + 129 * g + 25 * b + 16 * 256) >> 8, 0, 255);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _transform.ProcessMessage(TMessageType.MessageNotifyEndOfStream, 0);
        _transform.Dispose();
    }
}
