using System.Net.WebSockets;

namespace DeckWindowsAgent.Input;

public sealed class InputSessionRegistry
{
    private readonly object _gate = new();
    private Guid? _sessionId;
    private WebSocket? _socket;

    public bool TryReserve(out Guid sessionId)
    {
        lock (_gate)
        {
            if (_sessionId is not null) { sessionId = Guid.Empty; return false; }
            sessionId = Guid.NewGuid();
            _sessionId = sessionId;
            return true;
        }
    }

    public void Attach(Guid sessionId, WebSocket socket)
    {
        lock (_gate)
        {
            if (_sessionId != sessionId) throw new InvalidOperationException("Input session reservation was lost.");
            _socket = socket;
        }
    }

    public void End(Guid sessionId)
    {
        lock (_gate)
        {
            if (_sessionId != sessionId) return;
            _socket = null;
            _sessionId = null;
        }
    }

    public async ValueTask StopAllAsync(string reason, CancellationToken cancellationToken = default)
    {
        WebSocket? socket;
        lock (_gate) socket = _socket;
        if (socket?.State == WebSocketState.Open)
        {
            try { await socket.CloseOutputAsync(WebSocketCloseStatus.PolicyViolation, reason, cancellationToken); }
            catch (WebSocketException) { socket.Abort(); }
        }
    }
}
