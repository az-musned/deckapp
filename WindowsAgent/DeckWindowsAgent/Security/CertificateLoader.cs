using System.Security.Cryptography.X509Certificates;

namespace DeckWindowsAgent.Security;

public static class CertificateLoader
{
    public static X509Certificate2 LoadCurrentUserCertificate(string thumbprint)
    {
        var normalized = thumbprint.Replace(" ", string.Empty, StringComparison.Ordinal).ToUpperInvariant();
        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
        var matches = store.Certificates.Find(X509FindType.FindByThumbprint, normalized, validOnly: true);
        var certificate = matches.OfType<X509Certificate2>().FirstOrDefault(c => c.HasPrivateKey);
        return certificate ?? throw new InvalidOperationException(
            "The configured valid TLS certificate with a private key was not found in CurrentUser/My.");
    }
}
