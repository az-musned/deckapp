namespace DeckWindowsAgent.Safety;

public sealed record AgentSecuritySnapshot(
    bool RemoteInputAllowed,
    bool EmergencyInputDisabled,
    bool InputInjectionAvailable,
    bool ScreenShareAllowed,
    int ProtocolVersion);

public sealed class AgentSafetyState
{
    private int _remoteInputAllowed;
    private int _emergencyInputDisabled;
    private int _screenShareAllowed;

    public AgentSafetyState(bool remoteInputAllowed = true, bool screenShareAllowed = false)
    {
        _remoteInputAllowed = remoteInputAllowed ? 1 : 0;
        _screenShareAllowed = screenShareAllowed ? 1 : 0;
    }

    public bool RemoteInputAllowed => Volatile.Read(ref _remoteInputAllowed) == 1;
    public bool EmergencyInputDisabled => Volatile.Read(ref _emergencyInputDisabled) == 1;
    public bool ScreenShareAllowed => Volatile.Read(ref _screenShareAllowed) == 1;

    public void SetRemoteInputAllowed(bool allowed) => Interlocked.Exchange(ref _remoteInputAllowed, allowed ? 1 : 0);
    public void SetEmergencyInputDisabled(bool disabled) => Interlocked.Exchange(ref _emergencyInputDisabled, disabled ? 1 : 0);
    public void SetScreenShareAllowed(bool allowed) => Interlocked.Exchange(ref _screenShareAllowed, allowed ? 1 : 0);
}
