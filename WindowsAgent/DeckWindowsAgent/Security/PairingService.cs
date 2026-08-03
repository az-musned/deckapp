using System.Security.Cryptography;
using System.Text;
using DeckWindowsAgent.Configuration;

namespace DeckWindowsAgent.Security;

public sealed class PairingService
{
    public const int ProtocolVersion = 1;
    private readonly PairingStore _store;
    private readonly AgentOptions _options;
    private readonly Action<PairingCodePresentation> _presentCode;
    private readonly object _gate = new();
    private readonly Dictionary<Guid, ActivePairingChallenge> _challenges = [];

    public PairingService(
        PairingStore store,
        AgentOptions options,
        Action<PairingCodePresentation>? presentCode = null)
    {
        _store = store;
        _options = options;
        _presentCode = presentCode ?? (presentation => Console.WriteLine(
            $"Pairing request for {presentation.DeviceName}: {presentation.Code} (expires {presentation.ExpiresAt:HH:mm:ss} UTC)"));
    }

    public PairingChallengeResponse Start(PairingStartRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.ClientDeviceId) || string.IsNullOrWhiteSpace(request.DeviceName))
            throw new ArgumentException("ClientDeviceId and DeviceName are required.");

        var challenge = new ActivePairingChallenge
        {
            Id = Guid.NewGuid(),
            ClientDeviceId = request.ClientDeviceId.Trim(),
            DeviceName = request.DeviceName.Trim()[..Math.Min(request.DeviceName.Trim().Length, 80)],
            Code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6"),
            ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(_options.PairingCodeLifetimeSeconds)
        };

        lock (_gate)
        {
            RemoveExpiredChallenges();
            foreach (var id in _challenges
                         .Where(pair => pair.Value.ClientDeviceId == challenge.ClientDeviceId)
                         .Select(pair => pair.Key)
                         .ToArray())
                _challenges.Remove(id);
            if (_challenges.Count >= 8)
                throw new InvalidOperationException("Too many active pairing requests. Wait for an existing request to expire.");
            _challenges[challenge.Id] = challenge;
        }

        // This is deliberately presented locally and never sent back in the challenge response.
        _presentCode(new PairingCodePresentation(challenge.DeviceName, challenge.Code, challenge.ExpiresAt));
        return new PairingChallengeResponse(challenge.Id, challenge.ExpiresAt, Environment.MachineName);
    }

    public PairingConfirmResponse Confirm(PairingConfirmRequest request)
    {
        ActivePairingChallenge challenge;
        lock (_gate)
        {
            RemoveExpiredChallenges();
            if (!_challenges.TryGetValue(request.ChallengeId, out challenge!))
                throw new UnauthorizedAccessException("Pairing challenge is missing or expired.");

            challenge.Attempts++;
            if (challenge.Attempts > _options.MaximumPairingAttempts)
            {
                _challenges.Remove(challenge.Id);
                throw new UnauthorizedAccessException("Pairing attempt limit exceeded.");
            }

            if (!string.Equals(challenge.ClientDeviceId, request.ClientDeviceId, StringComparison.Ordinal)
                || !FixedTimeEquals(challenge.Code, request.Code))
            {
                throw new UnauthorizedAccessException("Pairing code was rejected.");
            }
            _challenges.Remove(challenge.Id);
        }

        var token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        var device = new PairedDevice(
            Guid.NewGuid(), challenge.ClientDeviceId, challenge.DeviceName,
            DateTimeOffset.UtcNow, HashToken(token));
        _store.Upsert(device);
        return new PairingConfirmResponse(device.Id, token, ProtocolVersion);
    }

    public bool Authenticate(string token) => AuthenticateDevice(token) is not null;

    public PairedDevice? AuthenticateDevice(string token)
    {
        if (string.IsNullOrWhiteSpace(token)) return null;
        var candidate = Convert.FromHexString(HashToken(token));
        return _store.Snapshot().FirstOrDefault(device =>
            CryptographicOperations.FixedTimeEquals(candidate, Convert.FromHexString(device.TokenHash)));
    }

    public IReadOnlyList<PairedDevice> PairedDevices() => _store.Snapshot();
    public bool Revoke(Guid id) => _store.Revoke(id);

    private void RemoveExpiredChallenges()
    {
        var now = DateTimeOffset.UtcNow;
        foreach (var id in _challenges.Where(pair => pair.Value.ExpiresAt <= now).Select(pair => pair.Key).ToArray())
            _challenges.Remove(id);
    }

    private static string HashToken(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));

    private static bool FixedTimeEquals(string expected, string supplied)
    {
        var expectedBytes = Encoding.UTF8.GetBytes(expected);
        var suppliedBytes = Encoding.UTF8.GetBytes(supplied);
        return expectedBytes.Length == suppliedBytes.Length
            && CryptographicOperations.FixedTimeEquals(expectedBytes, suppliedBytes);
    }
}
