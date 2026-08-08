using DeckWindowsAgent.Protocol;

namespace DeckWindowsAgent.Input;

public sealed class InputBatchProcessor
{
    public const int MaximumEventsPerBatch = 64;
    public const long StalePointerMilliseconds = 100;
    public const long StaleDiscreteMilliseconds = 2_000;
    private readonly IWindowsInputSink _sink;
    private readonly Guid _sessionId;
    private ulong _lastAcceptedSequence;
    private long? _clientToServerClockOffset;

    public InputBatchProcessor(IWindowsInputSink sink, Guid? sessionId = null)
    {
        _sink = sink;
        _sessionId = sessionId ?? Guid.NewGuid();
    }

    public async ValueTask<InputBatchResult> ProcessAsync(InputBatchRequest batch, CancellationToken cancellationToken)
    {
        if (batch.ProtocolVersion != Security.PairingService.ProtocolVersion)
            throw new InvalidOperationException("Unsupported protocol version.");
        if (batch.Events is null || batch.Events.Count is < 1 or > MaximumEventsPerBatch)
            throw new InvalidOperationException("Input batch size is invalid.");

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var latestClientTimestamp = batch.Events.Max(eventValue => eventValue.TimestampMilliseconds);
        if (latestClientTimestamp is <= 0 or > 253_402_300_799_000)
            throw new InvalidOperationException("Input timestamp is invalid.");
        _clientToServerClockOffset ??= now - latestClientTimestamp;
        var applied = 0;
        var dropped = 0;
        double pointerX = 0, pointerY = 0, scrollX = 0, scrollY = 0;
        bool acceleration = false, precision = false;

        async ValueTask FlushMotionAsync()
        {
            if (pointerX != 0 || pointerY != 0)
            {
                await _sink.ApplyAsync(_sessionId, new RelativePointerCommand(pointerX, pointerY, acceleration, precision), cancellationToken);
                applied++;
            }
            if (scrollX != 0 || scrollY != 0)
            {
                await _sink.ApplyAsync(_sessionId, new ScrollCommand(scrollX, scrollY), cancellationToken);
                applied++;
            }
            pointerX = pointerY = scrollX = scrollY = 0;
        }

        foreach (var envelope in batch.Events.OrderBy(eventValue => eventValue.Sequence))
        {
            if (envelope.Sequence <= _lastAcceptedSequence)
            {
                dropped++;
                continue;
            }
            _lastAcceptedSequence = envelope.Sequence;
            if (envelope.TimestampMilliseconds is <= 0 or > 253_402_300_799_000)
                throw new InvalidOperationException("Input timestamp is invalid.");
            var command = InputPayloadParser.Parse(envelope.Payload);
            var calibratedTimestamp = envelope.TimestampMilliseconds + _clientToServerClockOffset.Value;
            var age = now - calibratedTimestamp;
            var fromFuture = age < -5_000;

            if (command is RelativePointerCommand pointer)
            {
                if (fromFuture || age > StalePointerMilliseconds) { dropped++; continue; }
                pointerX += pointer.DeltaX;
                pointerY += pointer.DeltaY;
                acceleration = pointer.Acceleration;
                precision = pointer.Precision;
                continue;
            }
            if (command is ScrollCommand scroll)
            {
                if (fromFuture || age > StalePointerMilliseconds) { dropped++; continue; }
                scrollX += scroll.DeltaX;
                scrollY += scroll.DeltaY;
                continue;
            }

            await FlushMotionAsync();
            if ((fromFuture || age > StaleDiscreteMilliseconds) && !InputPayloadParser.IsReleasePriority(command))
            {
                dropped++;
                continue;
            }
            await _sink.ApplyAsync(_sessionId, command, cancellationToken);
            applied++;
        }

        await FlushMotionAsync();
        return new InputBatchResult(_lastAcceptedSequence, applied, dropped, "applied", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }
}
