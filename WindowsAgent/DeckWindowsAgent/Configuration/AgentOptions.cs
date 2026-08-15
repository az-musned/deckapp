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
    public bool RemoteInputEnabledByDefault { get; init; } = true;
    public bool ScreenShareEnabledByDefault { get; init; }
    public int MaximumInputClients { get; init; } = 2;
    public CapabilityOptions Capabilities { get; init; } = new();
    public AudioMeterOptions AudioMeters { get; init; } = new();
    public ScreenStreamOptions ScreenStream { get; init; } = new();

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
        if (MaximumInputClients is < 1 or > 4)
            throw new InvalidOperationException("Agent:MaximumInputClients must be between 1 and 4.");

        Capabilities.Validate();
        AudioMeters.Validate();
        ScreenStream.Validate();
    }

    public IReadOnlyList<string> EffectiveBindAddresses => BindAddresses.Length > 0
        ? BindAddresses.Distinct(StringComparer.OrdinalIgnoreCase).ToArray()
        : [BindAddress];
}

public sealed class AudioMeterOptions
{
    public bool Enabled { get; init; } = true;
    public int LocalUpdatesPerSecond { get; init; } = 30;
    public int ReducedUpdatesPerSecond { get; init; } = 18;
    public int MaximumClients { get; init; } = 4;
    public bool DiagnosticLoggingEnabled { get; init; }
    public int DiagnosticLogIntervalSeconds { get; init; } = 30;
    public List<AudioMeterChannelOptions> Channels { get; init; } = [];

    public void Validate()
    {
        if (LocalUpdatesPerSecond is < 1 or > 60 || ReducedUpdatesPerSecond is < 1 or > 30)
            throw new InvalidOperationException("Audio meter update rates are outside their allowed ranges.");
        if (MaximumClients is < 1 or > 8)
            throw new InvalidOperationException("Agent:AudioMeters:MaximumClients must be between 1 and 8.");
        if (DiagnosticLogIntervalSeconds is < 10 or > 3600)
            throw new InvalidOperationException("Audio meter diagnostic logging interval must be between 10 and 3600 seconds.");

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var channel in Channels)
        {
            if (channel.Id.Length is < 1 or > 64 || channel.Id.Any(character =>
                    !(char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-')))
                throw new InvalidOperationException("Audio meter channel IDs contain unsupported characters.");
            if (!ids.Add(channel.Id)) throw new InvalidOperationException($"Duplicate audio meter channel ID '{channel.Id}'.");
            if (string.IsNullOrWhiteSpace(channel.DisplayName) || channel.DisplayName.Length > 100)
                throw new InvalidOperationException($"Audio meter channel '{channel.Id}' needs a display name.");
            if (channel.EndpointId is { Length: > 1024 })
                throw new InvalidOperationException($"Audio meter channel '{channel.Id}' endpoint ID is too long.");
        }
    }
}

public sealed class AudioMeterChannelOptions
{
    public string Id { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;
    public string? EndpointId { get; init; }
}

public sealed class ScreenStreamOptions
{
    public bool Enabled { get; init; } = true;
    public int TargetFps { get; init; } = 15;
    public int MaxWidth { get; init; } = 1920;
    public int BitrateKbps { get; init; } = 4000;
    public int MaximumClients { get; init; } = 2;
    public string? MirrorMonitorDeviceName { get; init; }
    public string? ExtendMonitorDeviceName { get; init; }

    // WebRTC's media path (ICE connectivity checks, then DTLS/SRTP) is a UDP connection
    // separate from the signaling WebSocket, and needs its own firewall allowance. Pinning
    // SIPSorcery to this narrow, fixed range -- instead of letting it pick an OS-ephemeral
    // port per connection -- is what makes a tightly scoped firewall rule possible at all;
    // Configure-LocalConnection.ps1's UDP rule must open exactly this range. Sized for
    // MaximumClients (4) plus headroom for a reconnect briefly overlapping the connection
    // it's replacing.
    public int IceUdpPortRangeStart { get; init; } = 50000;
    public int IceUdpPortRangeEnd { get; init; } = 50020;

    public void Validate()
    {
        if (TargetFps is < 5 or > 60)
            throw new InvalidOperationException("Agent:ScreenStream:TargetFps must be between 5 and 60.");
        if (MaxWidth is < 640 or > 3840)
            throw new InvalidOperationException("Agent:ScreenStream:MaxWidth must be between 640 and 3840.");
        if (BitrateKbps is < 500 or > 20000)
            throw new InvalidOperationException("Agent:ScreenStream:BitrateKbps must be between 500 and 20000.");
        if (MaximumClients is < 1 or > 4)
            throw new InvalidOperationException("Agent:ScreenStream:MaximumClients must be between 1 and 4.");
        if (IceUdpPortRangeStart is < 1024 or > 65534 || IceUdpPortRangeEnd <= IceUdpPortRangeStart || IceUdpPortRangeEnd > 65535)
            throw new InvalidOperationException("Agent:ScreenStream:IceUdpPortRangeStart/End must describe a valid range within 1024-65535.");
    }
}

public sealed class CapabilityOptions
{
    public bool WindowsAudioEnabled { get; init; } = true;
    public bool GoXlrEnabled { get; init; } = true;
    public string GoXlrClientPath { get; init; } = string.Empty;
    public List<ApplicationLaunchOptions> Applications { get; init; } = [];

    public void Validate()
    {
        if (!string.IsNullOrWhiteSpace(GoXlrClientPath) && !Path.IsPathFullyQualified(GoXlrClientPath))
            throw new InvalidOperationException("Agent:Capabilities:GoXlrClientPath must be an absolute path.");

        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var application in Applications)
        {
            if (application.Id.Length is < 1 or > 64 || application.Id.Any(character =>
                    !(char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-')))
                throw new InvalidOperationException("Application IDs may contain only ASCII letters, digits, dot, underscore, and hyphen.");
            if (!ids.Add(application.Id)) throw new InvalidOperationException($"Duplicate application ID '{application.Id}'.");
            if (string.IsNullOrWhiteSpace(application.Name) || application.Name.Length > 100)
                throw new InvalidOperationException($"Application '{application.Id}' needs a name of at most 100 characters.");
            if (!Path.IsPathFullyQualified(application.ExecutablePath) ||
                !string.Equals(Path.GetExtension(application.ExecutablePath), ".exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"Application '{application.Id}' must point to an absolute .exe path.");
            if (application.Kind is not ("application" or "game"))
                throw new InvalidOperationException($"Application '{application.Id}' kind must be 'application' or 'game'.");
        }
    }
}

public sealed class ApplicationLaunchOptions
{
    public string Id { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string Kind { get; init; } = "application";
    public string ExecutablePath { get; init; } = string.Empty;
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
