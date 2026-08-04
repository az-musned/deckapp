using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Protocol;

namespace DeckWindowsAgent.Capabilities;

public interface IWindowsAudioSessionService
{
    IReadOnlyList<AgentAudioSessionState> Snapshot();
    bool SetVolume(string id, double volume);
    bool SetMuted(string id, bool muted);
}

public sealed class WindowsAudioSessionService(AgentOptions options) : IWindowsAudioSessionService
{
    private static readonly Guid AudioSessionManager2Id = new("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
    private static readonly Guid DeviceEnumeratorClassId = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid EventContext = new("52DBF871-E448-47D5-8259-65089A808E91");
    private readonly bool _enabled = options.Capabilities.WindowsAudioEnabled;

    public IReadOnlyList<AgentAudioSessionState> Snapshot()
    {
        if (!_enabled) return [];
        var result = new Dictionary<string, AgentAudioSessionState>(StringComparer.Ordinal);
        VisitSessions((id, name, volume) =>
        {
            volume.GetMasterVolume(out var level);
            volume.GetMute(out var muted);
            result[id] = new AgentAudioSessionState(id, name, Math.Clamp(level, 0, 1), muted);
            return false;
        });
        return result.Values.OrderBy(session => session.Name, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public bool SetVolume(string id, double volume)
    {
        if (!_enabled || !double.IsFinite(volume) || volume is < 0 or > 1) return false;
        return VisitSessions((candidateId, _, control) =>
        {
            if (candidateId != id || control.SetMasterVolume((float)volume, EventContext) < 0) return false;
            return control.GetMasterVolume(out var observed) >= 0 && Math.Abs(observed - volume) <= 0.011;
        });
    }

    public bool SetMuted(string id, bool muted)
    {
        if (!_enabled) return false;
        return VisitSessions((candidateId, _, control) =>
        {
            if (candidateId != id || control.SetMute(muted, EventContext) < 0) return false;
            return control.GetMute(out var observed) >= 0 && observed == muted;
        });
    }

    private static bool VisitSessions(Func<string, string, ISimpleAudioVolume, bool> visitor)
    {
        IMMDeviceEnumerator? deviceEnumerator = null;
        IMMDevice? device = null;
        IAudioSessionManager2? manager = null;
        IAudioSessionEnumerator? sessions = null;
        try
        {
            var enumeratorType = Type.GetTypeFromCLSID(DeviceEnumeratorClassId)
                ?? throw new InvalidOperationException("Windows Core Audio is unavailable.");
            deviceEnumerator = (IMMDeviceEnumerator)(Activator.CreateInstance(enumeratorType)
                ?? throw new InvalidOperationException("Windows Core Audio could not be initialized."));
            Marshal.ThrowExceptionForHR(deviceEnumerator.GetDefaultAudioEndpoint(EDataFlow.Render, ERole.Multimedia, out device));
            Marshal.ThrowExceptionForHR(device.GetId(out var deviceId));
            var iid = AudioSessionManager2Id;
            Marshal.ThrowExceptionForHR(device.Activate(ref iid, ClsContext.All, IntPtr.Zero, out var managerObject));
            manager = (IAudioSessionManager2)managerObject;
            Marshal.ThrowExceptionForHR(manager.GetSessionEnumerator(out sessions));
            Marshal.ThrowExceptionForHR(sessions.GetCount(out var sessionCount));
            for (var sessionIndex = 0; sessionIndex < sessionCount; sessionIndex++)
            {
                IAudioSessionControl? session = null;
                try
                {
                    Marshal.ThrowExceptionForHR(sessions.GetSession(sessionIndex, out session));
                    var session2 = (IAudioSessionControl2)session;
                    var volume = (ISimpleAudioVolume)session;
                    Marshal.ThrowExceptionForHR(session2.GetSessionInstanceIdentifier(out var instanceId));
                    Marshal.ThrowExceptionForHR(session2.GetProcessId(out var processId));
                    session.GetDisplayName(out var displayName);
                    var name = SessionName(displayName, processId, session2.IsSystemSoundsSession() == 0);
                    var id = SessionId(deviceId, instanceId);
                    if (visitor(id, name, volume)) return true;
                }
                catch (COMException)
                {
                    // Sessions can disappear while Windows enumerates them.
                }
                finally { Release(session); }
            }
            return false;
        }
        catch (COMException)
        {
            // Machines without an active default render endpoint expose no audio sessions.
            return false;
        }
        finally
        {
            Release(sessions);
            Release(manager);
            Release(device);
            Release(deviceEnumerator);
        }
    }

    private static string SessionName(string? displayName, uint processId, bool systemSounds)
    {
        if (!string.IsNullOrWhiteSpace(displayName)) return displayName.Trim();
        if (systemSounds) return "System Sounds";
        try
        {
            using var process = Process.GetProcessById(checked((int)processId));
            return process.ProcessName;
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException)
        {
            return "Audio Session";
        }
    }

    private static string SessionId(string deviceId, string instanceId)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(deviceId + "\n" + instanceId));
        return "audio-" + Convert.ToHexString(digest.AsSpan(0, 12)).ToLowerInvariant();
    }

    private static void Release(object? value)
    {
        if (value is not null && Marshal.IsComObject(value)) Marshal.FinalReleaseComObject(value);
    }

    private enum EDataFlow { Render, Capture, All }
    private enum ERole { Console, Multimedia, Communications }
    [Flags] private enum DeviceState : uint { Active = 1 }
    [Flags] private enum ClsContext : uint { All = 23 }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, DeviceState stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-C0A2D0D4EEB1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, ClsContext context, IntPtr activationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out DeviceState state);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(ref Guid sessionId, uint flags, out IAudioSessionControl control);
        [PreserveSig] int GetSimpleAudioVolume(ref Guid sessionId, uint flags, out ISimpleAudioVolume volume);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator enumerator);
        [PreserveSig] int RegisterSessionNotification(IntPtr notification);
        [PreserveSig] int UnregisterSessionNotification(IntPtr notification);
        [PreserveSig] int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)] string sessionId, IntPtr notification);
        [PreserveSig] int UnregisterDuckNotification(IntPtr notification);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl session);
    }

    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string displayName);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid context);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid context);
        [PreserveSig] int GetGroupingParam(out Guid groupingId);
        [PreserveSig] int SetGroupingParam(ref Guid groupingId, ref Guid context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string displayName);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid context);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid context);
        [PreserveSig] int GetGroupingParam(out Guid groupingId);
        [PreserveSig] int SetGroupingParam(ref Guid groupingId, ref Guid context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint processId);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISimpleAudioVolume
    {
        [PreserveSig] int SetMasterVolume(float level, in Guid context);
        [PreserveSig] int GetMasterVolume(out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted, in Guid context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool muted);
    }
}
