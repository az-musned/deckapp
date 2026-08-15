using System.Net.WebSockets;
using System.Text.Json;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Screen.Models;
using DeckWindowsAgent.Security;
using SIPSorcery.Net;
using SIPSorcery.Sys;
using SIPSorceryMedia.Abstractions;

namespace DeckWindowsAgent.Screen;

/// This endpoint used to carry raw H.264 video bytes framed in a custom binary header. It
/// now only carries WebRTC signaling (SDP offer/answer + trickled ICE candidates) plus the
/// pre-existing keyframe-request control message; the video itself flows over the RTP/SRTP
/// connection SIPSorcery negotiates once signaling completes. Connection setup (auth, mode
/// reservation, capacity) is unchanged from the old binary-frame version.
public static class ScreenStreamWebSocketEndpoint
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private const int H264DynamicPayloadType = 96;

    public static void MapScreenStreamWebSocket(this WebApplication app) =>
        app.Map("/api/v1/screen/mirror/ws", HandleAsync);

    private static async Task HandleAsync(HttpContext context)
    {
        var pairing = context.RequestServices.GetRequiredService<PairingService>();
        var safety = context.RequestServices.GetRequiredService<AgentSafetyState>();
        var options = context.RequestServices.GetRequiredService<AgentOptions>();
        var streamService = context.RequestServices.GetRequiredService<ScreenStreamService>();
        var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
            .CreateLogger("DeckWindowsAgent.ScreenStreamWebSocket");

        if (!Authenticate(context, pairing)) { context.Response.StatusCode = StatusCodes.Status401Unauthorized; return; }
        if (!safety.ScreenShareAllowed) { context.Response.StatusCode = StatusCodes.Status403Forbidden; return; }
        if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = StatusCodes.Status400BadRequest; return; }

        var mode = string.Equals(context.Request.Query["mode"], "extend", StringComparison.OrdinalIgnoreCase)
            ? ScreenStreamMode.Extend
            : ScreenStreamMode.Mirror;

        ScreenStreamSubscription? subscription;
        string? conflictReason;
        try { subscription = streamService.TryReserveMode(mode, out conflictReason); }
        catch (InvalidOperationException error)
        {
            context.Response.StatusCode = StatusCodes.Status429TooManyRequests;
            await context.Response.WriteAsJsonAsync(new { error = error.Message });
            return;
        }

        if (subscription is null)
        {
            context.Response.StatusCode = StatusCodes.Status409Conflict;
            await context.Response.WriteAsJsonAsync(new { error = conflictReason });
            return;
        }

        using (subscription)
        using (var socket = await context.WebSockets.AcceptWebSocketAsync())
        using (var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted))
        // Pinning ICE/RTP to a narrow, fixed UDP port range (rather than SIPSorcery's default
        // OS-ephemeral-port choice per connection) is what makes it possible for
        // Configure-LocalConnection.ps1 to open a tightly scoped firewall rule for the media
        // path at all -- see ScreenStreamOptions.IceUdpPortRangeStart/End. bindPort 0 lets
        // SIPSorcery pick the specific port within that range itself.
        using (var pc = new RTCPeerConnection(
            new RTCConfiguration { iceServers = [] },
            bindPort: 0,
            portRange: new PortRange(options.ScreenStream.IceUdpPortRangeStart, options.ScreenStream.IceUdpPortRangeEnd, false, null),
            videoAsPrimary: true))
        {
            var sendGate = new SemaphoreSlim(1, 1);
            logger.LogInformation("Authenticated screen mirror client connected in {Mode} mode.", mode);

            pc.addTrack(new MediaStreamTrack(
                new VideoFormat(VideoCodecsEnum.H264, H264DynamicPayloadType),
                MediaStreamStatusEnum.SendOnly));
            subscription.Attach(pc);

            pc.onicecandidate += candidate =>
            {
                if (candidate is null) return;
                _ = SendSignalAsync(socket, sendGate, new ScreenStreamSignal(
                    "ice", null, candidate.candidate, candidate.sdpMid,
                    candidate.sdpMLineIndex), linkedCts.Token);
            };
            pc.onconnectionstatechange += state =>
            {
                if (state is RTCPeerConnectionState.closed or RTCPeerConnectionState.failed or RTCPeerConnectionState.disconnected)
                    linkedCts.Cancel();
            };

            try
            {
                var expectedHeight = ExpectedHeight(mode, options);
                var hello = new ScreenStreamHello(
                    "screen.hello",
                    options.ScreenStream.MaxWidth,
                    expectedHeight,
                    options.ScreenStream.TargetFps,
                    "h264",
                    PairingService.ProtocolVersion,
                    mode == ScreenStreamMode.Extend ? "extend" : "mirror");
                await SendJsonAsync(socket, sendGate, hello, linkedCts.Token);

                await ReceiveSignalingMessagesAsync(socket, sendGate, pc, streamService, linkedCts.Token);
            }
            catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
            {
                // The HTTP request or application is shutting down.
            }
            catch (WebSocketException)
            {
                // The peer disconnected mid-negotiation.
            }
            finally
            {
                linkedCts.Cancel();
                pc.close();
                if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
                {
                    try { await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Closed.", CancellationToken.None); }
                    catch (WebSocketException) { /* Already closing. */ }
                }
                logger.LogInformation("Screen mirror client disconnected.");
            }
        }
    }

    private static async Task ReceiveSignalingMessagesAsync(
        WebSocket socket,
        SemaphoreSlim sendGate,
        RTCPeerConnection pc,
        ScreenStreamService streamService,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[16 * 1024];
        while (!cancellationToken.IsCancellationRequested && socket.State == WebSocketState.Open)
        {
            using var messageStream = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await socket.ReceiveAsync(buffer, cancellationToken);
                if (result.MessageType == WebSocketMessageType.Close) return;
                messageStream.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);

            if (result.MessageType != WebSocketMessageType.Text || messageStream.Length == 0) continue;
            await HandleSignalingMessageAsync(socket, sendGate, pc, streamService, messageStream.ToArray(), cancellationToken);
        }
    }

    private static async Task HandleSignalingMessageAsync(
        WebSocket socket,
        SemaphoreSlim sendGate,
        RTCPeerConnection pc,
        ScreenStreamService streamService,
        byte[] payload,
        CancellationToken cancellationToken)
    {
        ScreenStreamSignal? signal;
        try { signal = JsonSerializer.Deserialize<ScreenStreamSignal>(payload, JsonOptions); }
        catch (JsonException) { return; }
        if (signal is null) return;

        switch (signal.Type)
        {
            case "screen.requestKeyframe":
                streamService.RequestKeyframe();
                break;

            case "offer" when signal.Sdp is { } offerSdp:
                pc.setRemoteDescription(new RTCSessionDescriptionInit { type = RTCSdpType.offer, sdp = offerSdp });
                var answer = pc.createAnswer();
                await pc.setLocalDescription(answer);
                await SendSignalAsync(socket, sendGate, new ScreenStreamSignal("answer", answer.sdp, null, null, null), cancellationToken);
                break;

            case "ice" when signal.Candidate is { } candidate:
                pc.addIceCandidate(new RTCIceCandidateInit
                {
                    candidate = candidate,
                    sdpMid = signal.SdpMid,
                    sdpMLineIndex = (ushort)(signal.SdpMLineIndex ?? 0),
                });
                break;
        }
    }

    private static Task SendSignalAsync(WebSocket socket, SemaphoreSlim sendGate, ScreenStreamSignal signal, CancellationToken cancellationToken) =>
        SendJsonAsync(socket, sendGate, signal, cancellationToken);

    private static async Task SendJsonAsync<T>(WebSocket socket, SemaphoreSlim sendGate, T value, CancellationToken cancellationToken)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions);
        await sendGate.WaitAsync(cancellationToken);
        try
        {
            if (socket.State != WebSocketState.Open) return;
            await socket.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken);
        }
        catch (WebSocketException)
        {
            // The peer disconnected; nothing left to do with this send.
        }
        finally
        {
            sendGate.Release();
        }
    }

    private static int ExpectedHeight(ScreenStreamMode mode, AgentOptions options)
    {
        var deviceName = mode == ScreenStreamMode.Extend
            ? options.ScreenStream.ExtendMonitorDeviceName
            : options.ScreenStream.MirrorMonitorDeviceName;

        var target = string.IsNullOrWhiteSpace(deviceName)
            ? MonitorEnumerator.EnumerateAll().FirstOrDefault(monitor => monitor.IsPrimary)
            : MonitorEnumerator.EnumerateAll().FirstOrDefault(monitor => monitor.DeviceName == deviceName);

        if (target.Width <= 0) return 0;
        var scale = Math.Min(1.0, options.ScreenStream.MaxWidth / (double)target.Width);
        return (int)Math.Round(target.Height * scale);
    }

    private static bool Authenticate(HttpContext context, PairingService pairing)
    {
        var authorization = context.Request.Headers.Authorization.ToString();
        const string prefix = "Bearer ";
        return authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && pairing.Authenticate(authorization[prefix.Length..].Trim());
    }
}
