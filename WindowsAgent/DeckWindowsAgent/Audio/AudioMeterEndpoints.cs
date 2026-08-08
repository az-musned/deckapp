using DeckWindowsAgent.Audio.Models;
using DeckWindowsAgent.Security;

namespace DeckWindowsAgent.Audio;

public static class AudioMeterEndpoints
{
    public static void MapAudioMeterEndpoints(this WebApplication app)
    {
        app.MapGet("/api/v1/audio/endpoints", (HttpContext context, PairingService pairing, AudioMeterService meters) =>
        {
            if (!Authenticate(context, pairing)) return Results.Unauthorized();
            return Results.Ok(new { endpoints = meters.Endpoints, protocolVersion = PairingService.ProtocolVersion });
        });

        app.MapGet("/api/v1/audio/channels", (HttpContext context, PairingService pairing, AudioMeterService meters) =>
        {
            if (!Authenticate(context, pairing)) return Results.Unauthorized();
            return Results.Ok(new { channels = meters.Channels, protocolVersion = PairingService.ProtocolVersion });
        });

        app.MapPut("/api/v1/audio/channels/{channelId}/mapping", (
            string channelId,
            AudioChannelMappingRequest request,
            HttpContext context,
            PairingService pairing,
            AudioMeterService meters) =>
        {
            if (!Authenticate(context, pairing)) return Results.Unauthorized();
            if (request.EndpointId is { } endpointId && (string.IsNullOrWhiteSpace(endpointId) || endpointId.Length > 1024))
                return Results.BadRequest(new { error = "endpointId must be null or a valid endpoint ID." });
            if (!meters.TrySetMapping(channelId, request.EndpointId, out var error))
                return Results.Json(new { error }, statusCode: StatusCodes.Status409Conflict);
            return Results.Ok(new { channels = meters.Channels, protocolVersion = PairingService.ProtocolVersion });
        });
    }

    private static bool Authenticate(HttpContext context, PairingService pairing)
    {
        var authorization = context.Request.Headers.Authorization.ToString();
        const string prefix = "Bearer ";
        return authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && pairing.Authenticate(authorization[prefix.Length..].Trim());
    }
}
