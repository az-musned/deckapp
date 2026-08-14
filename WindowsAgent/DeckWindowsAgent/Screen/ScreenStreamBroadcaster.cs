using DeckWindowsAgent.Configuration;
using SIPSorcery.Net;

namespace DeckWindowsAgent.Screen;

/// Fans out encoded video to every connected client's RTCPeerConnection. Replaces the old
/// per-client bounded-channel-of-binary-frames design: RTP's own sequencing, jitter buffer,
/// and loss recovery now live in the WebRTC stack on both ends, so this class only needs to
/// track which peer connections are live and push each encoded sample to all of them.
public sealed class ScreenStreamBroadcaster(AgentOptions options)
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, RTCPeerConnection?> _subscribers = [];
    private readonly int _maximumClients = options.ScreenStream.MaximumClients;

    public int SubscriberCount { get { lock (_gate) return _subscribers.Count; } }

    /// Reserves a client slot before the SDP/ICE handshake begins, so MaximumClients is
    /// enforced immediately (429) rather than only after negotiation completes.
    public ScreenStreamSubscription Reserve()
    {
        lock (_gate)
        {
            if (_subscribers.Count >= _maximumClients)
                throw new InvalidOperationException("The maximum number of screen mirror clients is connected.");
            var id = Guid.NewGuid();
            _subscribers[id] = null;
            return new ScreenStreamSubscription(id, this);
        }
    }

    /// Called once the signaling endpoint has a live RTCPeerConnection for a reserved slot.
    internal void Attach(Guid id, RTCPeerConnection connection)
    {
        lock (_gate)
        {
            if (_subscribers.ContainsKey(id)) _subscribers[id] = connection;
        }
    }

    internal void Remove(Guid id)
    {
        lock (_gate) _subscribers.Remove(id);
    }

    public void Publish(EncodedFrame frame, uint durationRtpUnits)
    {
        List<RTCPeerConnection> targets;
        lock (_gate)
            targets = [.. _subscribers.Values.OfType<RTCPeerConnection>()];

        foreach (var pc in targets)
        {
            try
            {
                pc.SendVideo(durationRtpUnits, frame.AnnexB);
            }
            catch (Exception)
            {
                // The connection is closing/closed; its own close handler removes it from
                // _subscribers, so a send failure here is not otherwise actionable.
            }
        }
    }

    public void DisconnectAll()
    {
        List<RTCPeerConnection> targets;
        lock (_gate)
        {
            targets = [.. _subscribers.Values.OfType<RTCPeerConnection>()];
            _subscribers.Clear();
        }
        foreach (var pc in targets) pc.close();
    }
}

public sealed class ScreenStreamSubscription(Guid id, ScreenStreamBroadcaster broadcaster) : IDisposable
{
    public Guid Id { get; } = id;
    private int _disposed;

    public void Attach(RTCPeerConnection connection) => broadcaster.Attach(Id, connection);

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0) broadcaster.Remove(Id);
    }
}
