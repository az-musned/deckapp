using System.Security.Cryptography;
using System.Text;
using DotPulsar.Abstractions;

namespace DeckWindowsAgent.Tuya;

/// Implements Tuya's custom Pulsar SASL mechanism ("auth1"), a direct port of the password
/// derivation and payload shape from Tuya's own reference client
/// (github.com/tuya/tuya-pulsar-sdk-dotnet/blob/main/MyAuthentication.cs) -- this is
/// Tuya-specific, not part of the general Pulsar/AMQP protocol, so it can't be derived from
/// DotPulsar's own docs.
public sealed class TuyaPulsarAuthentication(string accessId, string accessSecret) : IAuthentication
{
    private readonly byte[] _authData = Encoding.UTF8.GetBytes(
        $"{{\"username\":\"{accessId}\", \"password\":\"{DerivePassword(accessId, accessSecret)}\"}}");

    public string AuthenticationMethodName => "auth1";

    public ValueTask<byte[]> GetAuthenticationData(CancellationToken cancellationToken) =>
        ValueTask.FromResult(_authData);

    private static string DerivePassword(string accessId, string accessSecret)
    {
        var secretHash = Md5Hex(accessSecret);
        var mixed = Md5Hex(accessId + secretHash);
        return mixed.Substring(8, 16);
    }

    private static string Md5Hex(string value)
    {
        var hash = MD5.HashData(Encoding.UTF8.GetBytes(value));
        var builder = new StringBuilder(hash.Length * 2);
        foreach (var b in hash) builder.Append(b.ToString("x2"));
        return builder.ToString();
    }
}
