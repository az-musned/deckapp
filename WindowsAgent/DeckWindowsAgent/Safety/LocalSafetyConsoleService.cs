using DeckWindowsAgent.Input;
using DeckWindowsAgent.Security;

namespace DeckWindowsAgent.Safety;

public sealed class LocalSafetyConsoleService : BackgroundService
{
    private readonly AgentSafetyState _safety;
    private readonly IWindowsInputSink _input;
    private readonly InputSessionRegistry _sessions;
    private readonly PairingService _pairing;

    public LocalSafetyConsoleService(
        AgentSafetyState safety,
        IWindowsInputSink input,
        InputSessionRegistry sessions,
        PairingService pairing)
    {
        _safety = safety;
        _input = input;
        _sessions = sessions;
        _pairing = pairing;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        Console.WriteLine("Local controls: [I] toggle remote input, [E] emergency disable, [P] paired devices, [R] revoke a device.");
        while (!stoppingToken.IsCancellationRequested)
        {
            if (Console.IsInputRedirected || !Console.KeyAvailable)
            {
                await Task.Delay(250, stoppingToken);
                continue;
            }

            switch (Console.ReadKey(intercept: true).Key)
            {
                case ConsoleKey.I:
                    _safety.SetRemoteInputAllowed(!_safety.RemoteInputAllowed);
                    if (!_safety.RemoteInputAllowed)
                    {
                        await _sessions.StopAllAsync("Input disabled on Windows.", CancellationToken.None);
                        await _input.ReleaseAllAsync(CancellationToken.None);
                    }
                    Console.WriteLine($"Allow Remote Input: {_safety.RemoteInputAllowed}");
                    break;
                case ConsoleKey.E:
                    _safety.SetEmergencyInputDisabled(!_safety.EmergencyInputDisabled);
                    await _sessions.StopAllAsync("Emergency Disable Input activated.", CancellationToken.None);
                    await _input.ReleaseAllAsync(CancellationToken.None);
                    Console.WriteLine($"Emergency Disable Input: {_safety.EmergencyInputDisabled}");
                    break;
                case ConsoleKey.P:
                    foreach (var device in _pairing.PairedDevices())
                        Console.WriteLine($"{device.Id}  {device.DeviceName}  paired {device.PairedAt:u}");
                    break;
                case ConsoleKey.R:
                    foreach (var device in _pairing.PairedDevices())
                        Console.WriteLine($"{device.Id}  {device.DeviceName}  paired {device.PairedAt:u}");
                    Console.Write("Paired device ID to revoke: ");
                    var supplied = Console.ReadLine();
                    Console.WriteLine(Guid.TryParse(supplied, out var id) && _pairing.Revoke(id)
                        ? "Device revoked."
                        : "No matching paired device.");
                    break;
            }
        }
    }
}
