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
        ConfigureRealtimeEncoding(_transform);

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

    /// Without this, Media Foundation's H.264 encoder defaults to using B-frames, which
    /// require frame reordering (decode order != presentation/RTP-send order). RTP timestamps
    /// here are assigned in simple encode-call order (see ScreenStreamService.RtpDurationUnits),
    /// which assumes no reordering -- correct for the zero-B-frame baseline/low-latency profile
    /// WebRTC expects, but not for a B-frame stream. With B-frames, a receiver decoding in
    /// arrival order keeps stalling on forward references it doesn't have yet, which is exactly
    /// the "frames received but not decoded" pattern that showed up in WebRTC receiver stats
    /// (framesReceived climbing far faster than framesDecoded, framesDropped tracking
    /// framesDecoded almost 1:1) during investigation of choppy ~1fps-looking playback despite
    /// a clean, steady encode/publish rate on this side. CODECAPI_AVEncCommonLowLatency is
    /// Microsoft's documented mechanism for disabling B-frames on its H.264 MFT; the explicit
    /// B-picture-count-0 call is a belt-and-suspenders in case a given encoder only honors that
    /// specific knob. Best-effort: not every encoder implementation (e.g. some hardware MFTs)
    /// supports every CODECAPI property, so failures here are swallowed rather than thrown --
    /// worst case the encoder falls back to its default (possibly B-frame-including) behavior.
    private static void ConfigureRealtimeEncoding(IMFTransform transform)
    {
        var codecApiGuid = typeof(ICodecApi).GUID;
        if (Marshal.QueryInterface(transform.NativePointer, in codecApiGuid, out var codecApiPointer) != 0) return;
        try
        {
            var codecApi = (ICodecApi)Marshal.GetTypedObjectForIUnknown(codecApiPointer, typeof(ICodecApi));
            TrySetValue(codecApi, CodecApiGuids.AVEncCommonLowLatency, true);
            TrySetValue(codecApi, CodecApiGuids.AVEncCommonRealTime, true);
            TrySetValue(codecApi, CodecApiGuids.AVEncMPVDefaultBPictureCount, 0u);
            // CBR (eAVEncCommonRateControlMode_CBR = 0): many MF encoders default to a
            // VBR/quality-targeting rate control mode that buffers several frames internally to
            // smooth bitrate against a quality target, adding encode-side latency on top of the
            // B-frame reordering fixed above. CBR trades some quality for not doing that.
            TrySetValue(codecApi, CodecApiGuids.AVEncCommonRateControlMode, 0u);
        }
        finally
        {
            Marshal.Release(codecApiPointer);
        }

        // Deliberately not using a `ref object` SetValue signature: letting the CLR's
        // built-in "automatic VARIANT" COM interop marshal an `object` parameter for a
        // custom interface method is a .NET Framework-era feature that .NET (Core) doesn't
        // implement -- confirmed by testing in an isolated harness first, where it threw
        // NotImplementedException on every call rather than reaching the actual encoder.
        // Building the VARIANT explicitly via Marshal.GetNativeVariantForObject and passing
        // it as a plain IntPtr avoids that gap. Not every property is supported by every
        // encoder MFT (E_NOTIMPL is common and fine -- best-effort, not fatal); B-picture
        // count specifically is the one that matters here and is broadly supported.
        static void TrySetValue(ICodecApi codecApi, Guid api, object value)
        {
            var variant = Marshal.AllocHGlobal(16);
            try
            {
                Marshal.GetNativeVariantForObject(value, variant);
                codecApi.SetValue(ref api, variant);
            }
            finally
            {
                NativeMethods.VariantClear(variant);
                Marshal.FreeHGlobal(variant);
            }
        }
    }

    private static class CodecApiGuids
    {
        // From codecapi.h. Values verified against the Windows SDK header, not guessed --
        // getting one of these wrong would silently target the wrong (or no) encoder property.
        public static readonly Guid AVEncCommonLowLatency = new("9d3ecd55-89e8-490a-970a-0c9548d5a56e");
        public static readonly Guid AVEncCommonRealTime = new("143a0ff6-a131-43da-b81e-98fbb8ec378e");
        public static readonly Guid AVEncMPVDefaultBPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");
        public static readonly Guid AVEncCommonRateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    }

    private static class NativeMethods
    {
        [DllImport("oleaut32.dll", PreserveSig = false)]
        public static extern void VariantClear(IntPtr variant);
    }

    [ComImport]
    [Guid("901DB4C7-31CE-41A2-85DC-8FA0BF41B8DA")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICodecApi
    {
        [PreserveSig] int IsSupported(ref Guid api);
        [PreserveSig] int IsModifiable(ref Guid api);
        [PreserveSig] int GetParameterRange(ref Guid api, IntPtr min, IntPtr max, IntPtr delta);
        [PreserveSig] int GetParameterValues(ref Guid api, out IntPtr values, out uint count);
        [PreserveSig] int GetDefaultValue(ref Guid api, IntPtr value);
        [PreserveSig] int GetValue(ref Guid api, IntPtr value);
        [PreserveSig] int SetValue(ref Guid api, IntPtr value);
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
