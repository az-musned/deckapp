using System.Net.WebSockets;

namespace DeckWindowsAgent.Input;

public sealed class InputSessionRegistry
{
    private readonly object _gate = new();
    private readonly int _maximumSessions;
    private readonly Dictionary<Guid, WebSocket?> _sessions = [];

    public InputSessionRegistry(int maximumSessions = 2) => _maximumSessions = maximumSessions;

    public bool TryReserve(out Guid sessionId)
    {
        lock (_gate)
        {
            if (_sessions.Count >= _maximumSessions) { sessionId = Guid.Empty; return false; }
            sessionId = Guid.NewGuid();
            _sessions[sessionId] = null;
            return true;
        }
    }

    public void Attach(Guid sessionId, WebSocket socket)
    {
        lock (_gate)
        {
            if (!_sessions.ContainsKey(sessionId)) throw new InvalidOperationException("Input session reservation was lost.");
            _sessions[sessionId] = socket;
        }
    }

    public void End(Guid sessionId)
    {
        lock (_gate)
        {
            _sessions.Remove(sessionId);
        }
    }

    public async ValueTask StopAllAsync(string reason, CancellationToken cancellationToken = default)
    {
        WebSocket[] sockets;
        lock (_gate) sockets = _sessions.Values.OfType<WebSocket>().ToArray();
        foreach (var socket in sockets.Where(value => value.State == WebSocketState.Open))
        {
            try { await socket.CloseOutputAsync(WebSocketCloseStatus.PolicyViolation, reason, cancellationToken); }
            catch (WebSocketException) { socket.Abort(); }
        }
    }
}
