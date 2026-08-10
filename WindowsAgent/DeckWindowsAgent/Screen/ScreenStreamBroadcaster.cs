using System.Threading.Channels;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Screen.Models;

namespace DeckWindowsAgent.Screen;

public sealed class ScreenStreamBroadcaster(AgentOptions options)
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, Channel<ScreenFrame>> _subscribers = [];
    private readonly int _maximumClients = options.ScreenStream.MaximumClients;

    public int SubscriberCount { get { lock (_gate) return _subscribers.Count; } }

    public ScreenStreamSubscription Subscribe()
    {
        lock (_gate)
        {
            if (_subscribers.Count >= _maximumClients)
                throw new InvalidOperationException("The maximum number of screen mirror clients is connected.");
            var id = Guid.NewGuid();
            // Capacity > 1 (unlike the audio-meter broadcaster this was modeled on) is
            // deliberate: H.264 delta frames are differential, so dropping one mid-GOP
            // breaks the decoder's reference chain until the next keyframe. A small buffer
            // absorbs brief backpressure (e.g. a slow send of a large keyframe) without
            // needing to drop a frame the decode chain still depends on. Still bounded and
            // still drops under sustained backpressure -- the client detects the resulting
            // sequence gap and requests a fresh keyframe to resync (see
            // ScreenStreamSequenceTracker.accepts on the Swift side).
            var channel = Channel.CreateBounded<ScreenFrame>(new BoundedChannelOptions(4)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
                SingleWriter = true
            });
            _subscribers[id] = channel;
            return new ScreenStreamSubscription(channel.Reader, () => Remove(id));
        }
    }

    public void Publish(ScreenFrame frame)
    {
        lock (_gate)
            foreach (var channel in _subscribers.Values)
                channel.Writer.TryWrite(frame);
    }

    public void DisconnectAll()
    {
        lock (_gate)
        {
            foreach (var channel in _subscribers.Values) channel.Writer.TryComplete();
            _subscribers.Clear();
        }
    }

    private void Remove(Guid id)
    {
        lock (_gate)
            if (_subscribers.Remove(id, out var channel)) channel.Writer.TryComplete();
    }
}

public sealed class ScreenStreamSubscription(ChannelReader<ScreenFrame> reader, Action dispose) : IDisposable
{
    private int _disposed;
    public ChannelReader<ScreenFrame> Reader { get; } = reader;
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0) dispose();
    }
}
