using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TuyaGoveeBridge.Tuya;

/// Controls Tuya-native lights via Tuya's Cloud REST API (openapi.tuya*.com) -- separate from
/// the Pulsar message service TuyaButtonBridgeService subscribes to, and separate from Govee's
/// API that GoveeClient talks to. Signing matches the iOS app's TuyaCloudPlugService.swift and
/// Tuya's official OpenAPI signing scheme: HMAC-SHA256 over
/// client_id + access_token + t + (method + "\n" + sha256(body) + "\n\n" + path), uppercased hex.
public sealed class TuyaLightClient(IHttpClientFactory httpClientFactory, ILogger<TuyaLightClient> logger)
{
    private string? _cachedAccessToken;
    private DateTimeOffset _accessTokenExpiresAt = DateTimeOffset.MinValue;
    private readonly SemaphoreSlim _tokenLock = new(1, 1);

    // Bounds every outgoing request so one slow/hung call to Tuya can't stall the bridge's
    // single-threaded button-press loop for the .NET default HttpClient timeout (100s) --
    // observed live: a status read for one light hung long enough that every other button press
    // appeared completely unresponsive until it finally gave up.
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(10);

    public Task TurnOnAsync(string deviceId, string powerCode, TuyaDataCenter dataCenter, string accessId, string accessSecret, CancellationToken cancellationToken) =>
        SendCommandAsync(deviceId, powerCode, true, dataCenter, accessId, accessSecret, cancellationToken);

    public Task TurnOffAsync(string deviceId, string powerCode, TuyaDataCenter dataCenter, string accessId, string accessSecret, CancellationToken cancellationToken) =>
        SendCommandAsync(deviceId, powerCode, false, dataCenter, accessId, accessSecret, cancellationToken);

    /// Applies one on/off action to several Tuya lights as a single group, mirroring
    /// GoveeClient.ApplyAsync -- "toggle" decides direction once from the first target's current
    /// state so repeated presses can't drift the lights out of sync with each other.
    public async Task ApplyAsync(
        string action, IReadOnlyList<(string DeviceId, string PowerCode)> targets,
        TuyaDataCenter dataCenter, string accessId, string accessSecret, CancellationToken cancellationToken)
    {
        if (targets.Count == 0) return;

        var powerOn = action switch
        {
            "turnOn" => true,
            "turnOff" => false,
            _ => !(await TryGetPowerStateAsync(targets[0].DeviceId, targets[0].PowerCode, dataCenter, accessId, accessSecret, cancellationToken) ?? false)
        };

        foreach (var target in targets)
            await SendCommandAsync(target.DeviceId, target.PowerCode, powerOn, dataCenter, accessId, accessSecret, cancellationToken);
    }

    private async Task SendCommandAsync(
        string deviceId, string powerCode, bool powerOn,
        TuyaDataCenter dataCenter, string accessId, string accessSecret, CancellationToken cancellationToken)
    {
        try
        {
            var body = JsonSerializer.Serialize(new
            {
                commands = new[] { new { code = powerCode, value = powerOn } }
            });

            var response = await SendSignedRequestAsync(HttpMethod.Post, $"/v1.0/devices/{deviceId}/commands", body, dataCenter, accessId, accessSecret, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);
                logger.LogWarning("Tuya command request for {DeviceId} failed ({Status}): {Body}", deviceId, response.StatusCode, responseBody);
            }
        }
        catch (Exception error)
        {
            logger.LogWarning(error, "Tuya command request for {DeviceId} failed.", deviceId);
        }
    }

    private async Task<bool?> TryGetPowerStateAsync(
        string deviceId, string powerCode, TuyaDataCenter dataCenter, string accessId, string accessSecret, CancellationToken cancellationToken)
    {
        try
        {
            var response = await SendSignedRequestAsync(HttpMethod.Get, $"/v1.0/devices/{deviceId}/status", null, dataCenter, accessId, accessSecret, cancellationToken);
            if (!response.IsSuccessStatusCode) return null;

            using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
            if (!document.RootElement.TryGetProperty("result", out var result)) return null;

            foreach (var status in result.EnumerateArray())
            {
                if (status.GetProperty("code").GetString() != powerCode) continue;
                var value = status.GetProperty("value");
                return value.ValueKind == JsonValueKind.True || (value.ValueKind == JsonValueKind.Number && value.GetInt32() != 0);
            }
            return null;
        }
        catch (Exception error)
        {
            logger.LogWarning("Tuya status request for {DeviceId} failed: {Message}", deviceId, error.Message);
            return null;
        }
    }

    private async Task<HttpResponseMessage> SendSignedRequestAsync(
        HttpMethod method, string path, string? body,
        TuyaDataCenter dataCenter, string accessId, string accessSecret, CancellationToken cancellationToken)
    {
        var accessToken = await GetAccessTokenAsync(dataCenter, accessId, accessSecret, cancellationToken);
        var host = dataCenter.RestApiHost();

        using var client = httpClientFactory.CreateClient();
        using var request = new HttpRequestMessage(method, host + path);
        if (body is not null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");

        ApplySignatureHeaders(request, path, body, accessId, accessSecret, accessToken);
        return await SendWithTimeoutAsync(client, request, cancellationToken);
    }

    private async Task<string> GetAccessTokenAsync(TuyaDataCenter dataCenter, string accessId, string accessSecret, CancellationToken cancellationToken)
    {
        if (_cachedAccessToken is not null && DateTimeOffset.UtcNow < _accessTokenExpiresAt)
            return _cachedAccessToken;

        await _tokenLock.WaitAsync(cancellationToken);
        try
        {
            if (_cachedAccessToken is not null && DateTimeOffset.UtcNow < _accessTokenExpiresAt)
                return _cachedAccessToken;

            const string path = "/v1.0/token?grant_type=1";
            using var client = httpClientFactory.CreateClient();
            using var request = new HttpRequestMessage(HttpMethod.Get, dataCenter.RestApiHost() + path);
            ApplySignatureHeaders(request, path, null, accessId, accessSecret, accessToken: null);

            using var response = await SendWithTimeoutAsync(client, request, cancellationToken);
            response.EnsureSuccessStatusCode();
            var token = await response.Content.ReadFromJsonAsync<TuyaTokenResponse>(cancellationToken: cancellationToken)
                ?? throw new InvalidOperationException("Tuya token response was empty.");
            if (!token.Success || token.Result is null)
                throw new InvalidOperationException($"Tuya token request failed: {token.Msg}");

            _cachedAccessToken = token.Result.AccessToken;
            // Refresh a couple of minutes early rather than exactly at expiry, so a request that
            // starts just before the boundary doesn't race a token that expires mid-flight.
            _accessTokenExpiresAt = DateTimeOffset.UtcNow.AddSeconds(Math.Max(60, token.Result.ExpireTime - 120));
            return _cachedAccessToken;
        }
        finally
        {
            _tokenLock.Release();
        }
    }

    /// Tuya's OpenAPI signing scheme: sign = HMAC-SHA256(accessId + accessToken + t + stringToSign, accessSecret),
    /// uppercase hex. stringToSign = method + "\n" + sha256(body).lower-hex + "\n\n" + path. The
    /// access token is omitted from the signed string (and the header) for the token-fetch call
    /// itself, since there's no token yet at that point.
    private static void ApplySignatureHeaders(HttpRequestMessage request, string path, string? body, string accessId, string accessSecret, string? accessToken)
    {
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
        var contentHash = Sha256Hex(body ?? string.Empty);
        var stringToSign = $"{request.Method.Method}\n{contentHash}\n\n{path}";
        var signPayload = accessId + (accessToken ?? string.Empty) + timestamp + stringToSign;
        var signature = HmacSha256UpperHex(signPayload, accessSecret);

        request.Headers.Add("client_id", accessId);
        request.Headers.Add("sign", signature);
        request.Headers.Add("t", timestamp);
        request.Headers.Add("sign_method", "HMAC-SHA256");
        if (accessToken is not null) request.Headers.Add("access_token", accessToken);
    }

    private static async Task<HttpResponseMessage> SendWithTimeoutAsync(HttpClient client, HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(RequestTimeout);
        return await client.SendAsync(request, timeoutCts.Token);
    }

    private static string Sha256Hex(string value)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexStringLower(hash);
    }

    private static string HmacSha256UpperHex(string message, string secret)
    {
        var hash = HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), Encoding.UTF8.GetBytes(message));
        return Convert.ToHexString(hash); // Convert.ToHexString is already uppercase.
    }

    private sealed class TuyaTokenResponse
    {
        [JsonPropertyName("success")] public bool Success { get; init; }
        [JsonPropertyName("msg")] public string? Msg { get; init; }
        [JsonPropertyName("result")] public TuyaTokenResult? Result { get; init; }
    }

    private sealed class TuyaTokenResult
    {
        [JsonPropertyName("access_token")] public string AccessToken { get; init; } = string.Empty;
        [JsonPropertyName("expire_time")] public int ExpireTime { get; init; }
    }
}
