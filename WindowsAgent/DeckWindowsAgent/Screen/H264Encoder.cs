using System.Runtime.InteropServices;
using SharpGen.Runtime;
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

        var buffer = MediaFactory.MFCreateMemoryBuffer(nv12.Length);
        buffer.Lock(out var destination, out _, out _);
        Marshal.Copy(nv12, 0, destination, nv12.Length);
        buffer.Unlock();
        buffer.CurrentLength = nv12.Length;

        var sample = MediaFactory.MFCreateSample();
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
            var outputBuffer = MediaFactory.MFCreateMemoryBuffer(Math.Max(outputInfo.Size, 1));
            var outputSample = MediaFactory.MFCreateSample();
            outputSample.AddBuffer(outputBuffer);
            var dataBuffer = new OutputDataBuffer { StreamID = 0, Sample = outputSample };

            var result = _transform.ProcessOutput(ProcessOutputFlags.None, 1, ref dataBuffer, out _);
            if (result.Failure) return;

            var contiguous = dataBuffer.Sample.ConvertToContiguousBuffer();
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
        var ySize = targetWidth * targetHeight;
        var nv12 = new byte[ySize + ySize / 2];
        var bgra = frame.Bgra;
        var stride = frame.Stride;

        for (var y = 0; y < targetHeight; y++)
        {
            var sourceRow = Math.Min(y, frame.Height - 1) * stride;
            for (var x = 0; x < targetWidth; x++)
            {
                var sourceColumn = Math.Min(x, frame.Width - 1) * 4;
                var offset = sourceRow + sourceColumn;
                if (offset + 2 >= bgra.Length) continue;
                byte b = bgra[offset];
                byte g = bgra[offset + 1];
                byte r = bgra[offset + 2];
                nv12[y * targetWidth + x] = (byte)Math.Clamp(0.299 * r + 0.587 * g + 0.114 * b, 0, 255);
            }
        }

        var uvWidth = targetWidth / 2;
        var uvHeight = targetHeight / 2;
        var uvOffset = ySize;
        for (var y = 0; y < uvHeight; y++)
        {
            var sourceRow = Math.Min(y * 2, frame.Height - 1) * stride;
            for (var x = 0; x < uvWidth; x++)
            {
                var sourceColumn = Math.Min(x * 2, frame.Width - 1) * 4;
                var offset = sourceRow + sourceColumn;
                if (offset + 2 >= bgra.Length) continue;
                byte b = bgra[offset];
                byte g = bgra[offset + 1];
                byte r = bgra[offset + 2];
                var u = Math.Clamp(-0.169 * r - 0.331 * g + 0.5 * b + 128, 0, 255);
                var v = Math.Clamp(0.5 * r - 0.419 * g - 0.081 * b + 128, 0, 255);
                var pairIndex = uvOffset + (y * uvWidth + x) * 2;
                nv12[pairIndex] = (byte)u;
                nv12[pairIndex + 1] = (byte)v;
            }
        }

        return nv12;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _transform.ProcessMessage(TMessageType.MessageNotifyEndOfStream, 0);
        _transform.Dispose();
    }
}
