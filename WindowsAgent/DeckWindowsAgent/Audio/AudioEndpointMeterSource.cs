using DeckWindowsAgent.Audio.Models;
using NAudio.CoreAudioApi;

namespace DeckWindowsAgent.Audio;

public interface IAudioEndpointMeterSource : IDisposable
{
    IReadOnlyList<AudioEndpointInfo> RefreshEndpoints();
    bool TryReadPeak(string endpointId, out float linearPeak);
}

public sealed class WindowsAudioEndpointMeterSource : IAudioEndpointMeterSource
{
    private readonly object _gate = new();
    private Dictionary<string, MMDevice> _devices = new(StringComparer.Ordinal);

    public IReadOnlyList<AudioEndpointInfo> RefreshEndpoints()
    {
        var replacement = new Dictionary<string, MMDevice>(StringComparer.Ordinal);
        var endpoints = new List<AudioEndpointInfo>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            DiscoverFlow(enumerator, DataFlow.Render, "render", replacement, endpoints);
            DiscoverFlow(enumerator, DataFlow.Capture, "capture", replacement, endpoints);
        }
        catch
        {
            foreach (var device in replacement.Values) device.Dispose();
            throw;
        }

        Dictionary<string, MMDevice> previous;
        lock (_gate)
        {
            previous = _devices;
            _devices = replacement;
        }
        foreach (var device in previous.Values) device.Dispose();
        return endpoints.OrderBy(endpoint => endpoint.DisplayName, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public bool TryReadPeak(string endpointId, out float linearPeak)
    {
        lock (_gate)
        {
            if (!_devices.TryGetValue(endpointId, out var device))
            {
                linearPeak = 0;
                return false;
            }
            try
            {
                linearPeak = Math.Clamp(device.AudioMeterInformation.MasterPeakValue, 0, 1);
                return true;
            }
            catch (Exception error) when (error is InvalidCastException or InvalidOperationException or ObjectDisposedException or System.Runtime.InteropServices.COMException)
            {
                linearPeak = 0;
                return false;
            }
        }
    }

    public void Dispose()
    {
        Dictionary<string, MMDevice> devices;
        lock (_gate)
        {
            devices = _devices;
            _devices = new(StringComparer.Ordinal);
        }
        foreach (var device in devices.Values) device.Dispose();
    }

    private static void DiscoverFlow(
        MMDeviceEnumerator enumerator,
        DataFlow flow,
        string flowName,
        IDictionary<string, MMDevice> devices,
        ICollection<AudioEndpointInfo> endpoints)
    {
        var collection = enumerator.EnumerateAudioEndPoints(flow, DeviceState.Active);
        for (var index = 0; index < collection.Count; index++)
        {
            var device = collection[index];
            string? endpointId = null;
            try
            {
                endpointId = device.ID;
                if (!devices.TryAdd(endpointId, device))
                {
                    device.Dispose();
                    continue;
                }
                endpoints.Add(GoXlrEndpointMatcher.Describe(endpointId, device.FriendlyName, flowName));
            }
            catch (Exception error) when (error is InvalidCastException or InvalidOperationException or ObjectDisposedException or System.Runtime.InteropServices.COMException)
            {
                if (endpointId is not null) devices.Remove(endpointId);
                device.Dispose();
            }
        }
    }
}
