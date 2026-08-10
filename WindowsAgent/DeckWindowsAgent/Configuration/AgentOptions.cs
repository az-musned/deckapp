using System.Net;

namespace DeckWindowsAgent.Configuration;

public sealed class AgentOptions
{
    public string BindAddress { get; init; } = IPAddress.Loopback.ToString();
    public string[] BindAddresses { get; init; } = [];
    public int Port { get; init; } = 8732;
    public string CertificateThumbprint { get; init; } = string.Empty;
    public int PairingCodeLifetimeSeconds { get; init; } = 120;
    public int MaximumPairingAttempts { get; init; } = 5;

    /// <summary>Discord Application client ID/secret (developer.discord.com) used for the local RPC bridge.
    /// Optional: when either is blank the Discord widget stays unavailable instead of failing startup.</summary>
    public string DiscordClientId { get; init; } = string.Empty;
    public string DiscordClientSecret { get; init; } = string.Empty;

    public void Validate()
    {
        var addresses = EffectiveBindAddresses;
        if (addresses.Count == 0 || addresses.Any(value =>
            !IPAddress.TryParse(value, out var address) || !PrivateNetworkGuard.IsPrivateOrLoopback(address)))
        {
            throw new InvalidOperationException("Agent bind addresses must be explicit loopback, LAN, or private-VPN IP addresses.");
        }

        if (Port is < 1024 or > 65535)
        {
            throw new InvalidOperationException("Agent:Port must be between 1024 and 65535.");
        }

        if (string.IsNullOrWhiteSpace(CertificateThumbprint))
        {
            throw new InvalidOperationException("Agent:CertificateThumbprint is required. The Agent never falls back to HTTP.");
        }

        if (PairingCodeLifetimeSeconds is < 30 or > 300 || MaximumPairingAttempts is < 1 or > 10)
        {
            throw new InvalidOperationException("Pairing safety settings are outside their allowed ranges.");
        }
    }

    public IReadOnlyList<string> EffectiveBindAddresses => BindAddresses.Length > 0
        ? BindAddresses.Distinct(StringComparer.OrdinalIgnoreCase).ToArray()
        : [BindAddress];
}

public static class PrivateNetworkGuard
{
    public static bool IsPrivateOrLoopback(IPAddress address)
    {
        if (IPAddress.IsLoopback(address)) return true;

        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        var bytes = address.GetAddressBytes();
        if (bytes.Length == 4)
        {
            return bytes[0] == 10
                || (bytes[0] == 172 && bytes[1] is >= 16 and <= 31)
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 100 && bytes[1] is >= 64 and <= 127); // Private VPN/CGNAT, including Tailscale.
        }

        return address.IsIPv6LinkLocal
            || (bytes.Length == 16 && (bytes[0] & 0xFE) == 0xFC)
            || address.Equals(IPAddress.IPv6Loopback);
    }
}
