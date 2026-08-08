using System.Threading.Channels;
using DeckWindowsAgent.Audio.Models;
using DeckWindowsAgent.Configuration;

namespace DeckWindowsAgent.Audio;

public sealed class AudioMeterBroadcaster(AgentOptions options)
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, Subscriber> _subscribers = [];
    private readonly int _maximumClients = options.AudioMeters.MaximumClients;
    private readonly long _reducedMinimumIntervalMilliseconds = Math.Max(1, 1000 / options.AudioMeters.ReducedUpdatesPerSecond);

    public int SubscriberCount { get { lock (_gate) return _subscribers.Count; } }
    public bool HasLocalSubscribers { get { lock (_gate) return _subscribers.Values.Any(subscriber => !subscriber.ReducedBandwidth); } }

    public AudioMeterSubscription Subscribe(bool reducedBandwidth)
    {
        lock (_gate)
        {
            if (_subscribers.Count >= _maximumClients)
                throw new InvalidOperationException("The maximum number of audio meter clients is connected.");
            var id = Guid.NewGuid();
            var channel = Channel.CreateBounded<AudioMeterSnapshot>(new BoundedChannelOptions(1)
            {
                FullMode = BoundedChannelFullMode.DropOldest,
                SingleReader = true,
                SingleWriter = true
            });
            _subscribers[id] = new Subscriber(reducedBandwidth, channel);
            return new AudioMeterSubscription(channel.Reader, () => Remove(id));
        }
    }

    public void Publish(AudioMeterSnapshot snapshot)
    {
        lock (_gate)
            foreach (var subscriber in _subscribers.Values)
            {
                if (subscriber.ReducedBandwidth &&
                    snapshot.Timestamp - subscriber.LastPublishedTimestamp < _reducedMinimumIntervalMilliseconds)
                    continue;
                if (subscriber.Channel.Writer.TryWrite(snapshot)) subscriber.LastPublishedTimestamp = snapshot.Timestamp;
            }
    }

    private void Remove(Guid id)
    {
        lock (_gate)
            if (_subscribers.Remove(id, out var subscriber)) subscriber.Channel.Writer.TryComplete();
    }

    private sealed class Subscriber(bool reducedBandwidth, Channel<AudioMeterSnapshot> channel)
    {
        public bool ReducedBandwidth { get; } = reducedBandwidth;
        public Channel<AudioMeterSnapshot> Channel { get; } = channel;
        public long LastPublishedTimestamp { get; set; }
    }
}

public sealed class AudioMeterSubscription(ChannelReader<AudioMeterSnapshot> reader, Action dispose) : IDisposable
{
    private int _disposed;
    public ChannelReader<AudioMeterSnapshot> Reader { get; } = reader;
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0) dispose();
    }
}
