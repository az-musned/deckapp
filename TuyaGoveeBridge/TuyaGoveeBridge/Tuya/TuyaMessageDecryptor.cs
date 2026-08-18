using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TuyaGoveeBridge.Tuya;

/// Decrypts a Pulsar message body from Tuya's message service. Port of
/// github.com/tuya/tuya-pulsar-sdk-dotnet/blob/main/AesUtil.cs, using System.Text.Json instead
/// of Newtonsoft (avoids a new package dependency) and AesGcm/Aes from System.Security.Cryptography
/// instead of the obsolete RijndaelManaged the reference uses for the ECB path. The AES key is
/// accessSecret.Substring(8, 16) -- not the raw secret -- per that reference; this was not
/// independently derivable from Tuya's public docs, which only say encryption is "encapsulated
/// in the SDK".
public static class TuyaMessageDecryptor
{
    /// <param name="encryptionMode">The Pulsar message property named "em" -- "aes_gcm" or
    /// anything else (legacy ECB).</param>
    /// <param name="rawBody">The raw (still-encrypted-inside) message body, e.g.
    /// {"data":"...","protocol":4,"pv":"2.0","sign":"...","t":...}.</param>
    public static string Decrypt(string? encryptionMode, byte[] rawBody, string accessSecret)
    {
        var json = Encoding.UTF8.GetString(rawBody);
        using var document = JsonDocument.Parse(json);
        var encodedData = document.RootElement.GetProperty("data").GetString()
            ?? throw new InvalidOperationException("Tuya Pulsar message body has no 'data' field.");
        var key = Encoding.UTF8.GetBytes(accessSecret.Substring(8, 16));

        var plaintext = string.Equals(encryptionMode, "aes_gcm", StringComparison.Ordinal)
            ? DecryptGcm(encodedData, key)
            : DecryptEcb(encodedData, key);

        // The reference client strips stray control characters the padding scheme can leave
        // behind; ECB with zero-padding in particular can trail NUL/whitespace bytes.
        return new string(plaintext.Where(character => !char.IsControl(character) || character == ' ').ToArray()).Trim();
    }

    private static string DecryptGcm(string base64, byte[] key)
    {
        var bytes = Convert.FromBase64String(base64);
        var nonce = bytes[..12];
        var tag = bytes[^16..];
        var ciphertext = bytes[12..^16];
        var plaintext = new byte[ciphertext.Length];
        using var aesGcm = new AesGcm(key, tagSizeInBytes: 16);
        aesGcm.Decrypt(nonce, ciphertext, tag, plaintext);
        return Encoding.UTF8.GetString(plaintext);
    }

    private static string DecryptEcb(string base64, byte[] key)
    {
        var bytes = Convert.FromBase64String(base64);
        using var aes = Aes.Create();
        aes.Mode = CipherMode.ECB;
        aes.KeySize = 128;
        aes.Key = key;
        // Zero padding (matching the reference exactly), not PKCS7 -- Tuya's ECB messages
        // aren't necessarily padded the .NET-standard way, and PKCS7 would throw on a mismatch.
        aes.Padding = PaddingMode.Zeros;
        using var decryptor = aes.CreateDecryptor();
        var plaintext = decryptor.TransformFinalBlock(bytes, 0, bytes.Length);
        return Encoding.UTF8.GetString(plaintext);
    }
}
