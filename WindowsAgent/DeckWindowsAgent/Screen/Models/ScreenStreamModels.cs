namespace DeckWindowsAgent.Screen.Models;

public enum ScreenStreamMode
{
    Mirror,
    Extend
}

public sealed record ScreenStreamHello(
    string Type,
    int Width,
    int Height,
    int Fps,
    string Format,
    int ProtocolVersion,
    string Mode);

/// A signaling message exchanged over the (still bearer-token-authenticated) WebSocket at
/// /api/v1/screen/mirror/ws. The socket no longer carries video bytes -- video flows over
/// the RTP/SRTP connection SIPSorcery negotiates -- it now only carries the SDP offer/answer,
/// trickled ICE candidates, and the pre-existing keyframe-request control message.
/// Exactly one of Sdp / Candidate is populated, depending on Type.
public sealed record ScreenStreamSignal(
    string Type,
    string? Sdp,
    string? Candidate,
    string? SdpMid,
    int? SdpMLineIndex);
