namespace TuyaGoveeBridge.Tuya;

/// Mirrors the regions in the iOS app's TuyaDataCenter (DeckApp/Models/TuyaModels.swift) so the
/// same region name can be configured in both places -- keep them in sync if a region is added.
/// Tuya's message service (Pulsar) only has four regional endpoints, coarser than the six
/// openapi.* REST hosts the phone talks to for the smart plug, so the Americas and Europe pairs
/// below collapse onto the same Pulsar host.
public enum TuyaDataCenter
{
    WestAmerica,
    EastAmerica,
    CentralEurope,
    WestEurope,
    China,
    India
}

public static class TuyaDataCenterExtensions
{
    public static string PulsarServiceUrl(this TuyaDataCenter dataCenter) => dataCenter switch
    {
        TuyaDataCenter.WestAmerica or TuyaDataCenter.EastAmerica => "pulsar+ssl://mqe.tuyaus.com:7285/",
        TuyaDataCenter.CentralEurope or TuyaDataCenter.WestEurope => "pulsar+ssl://mqe.tuyaeu.com:7285/",
        TuyaDataCenter.China => "pulsar+ssl://mqe.tuyacn.com:7285/",
        TuyaDataCenter.India => "pulsar+ssl://mqe.tuyain.com:7285/",
        _ => throw new ArgumentOutOfRangeException(nameof(dataCenter))
    };

    public static bool TryParse(string? value, out TuyaDataCenter dataCenter)
    {
        if (!string.IsNullOrWhiteSpace(value) && Enum.TryParse(value, ignoreCase: true, out TuyaDataCenter parsed))
        {
            dataCenter = parsed;
            return true;
        }
        dataCenter = TuyaDataCenter.CentralEurope;
        return false;
    }
}
