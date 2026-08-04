using System.Diagnostics;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Protocol;

namespace DeckWindowsAgent.Capabilities;

public interface IApplicationCapabilityService
{
    IReadOnlyList<AgentApplicationState> Snapshot();
    Task<bool> LaunchAsync(string id, CancellationToken cancellationToken);
}

public sealed class ApplicationCapabilityService(AgentOptions options) : IApplicationCapabilityService
{
    private readonly IReadOnlyList<ApplicationLaunchOptions> _applications = options.Capabilities.Applications;

    public IReadOnlyList<AgentApplicationState> Snapshot() => _applications
        .Select(application => new AgentApplicationState(
            application.Id,
            application.Name,
            application.Kind,
            IsRunning(application.ExecutablePath)))
        .ToArray();

    public async Task<bool> LaunchAsync(string id, CancellationToken cancellationToken)
    {
        var application = _applications.SingleOrDefault(candidate =>
            string.Equals(candidate.Id, id, StringComparison.OrdinalIgnoreCase))
            ?? throw new CapabilityUnavailableException("The application is not in the Windows-local allowlist.");
        var executablePath = Path.GetFullPath(application.ExecutablePath);
        if (!File.Exists(executablePath)) throw new CapabilityUnavailableException("The allowlisted application is not installed at its configured path.");

        if (!IsRunning(executablePath))
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = executablePath,
                WorkingDirectory = Path.GetDirectoryName(executablePath)!,
                UseShellExecute = false
            }) ?? throw new CapabilityUnavailableException("Windows did not start the allowlisted application.");
        }

        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (IsRunning(executablePath)) return true;
            await Task.Delay(100, cancellationToken);
        }
        return false;
    }

    private static bool IsRunning(string executablePath)
    {
        var expected = Path.GetFullPath(executablePath);
        var processName = Path.GetFileNameWithoutExtension(expected);
        foreach (var process in Process.GetProcessesByName(processName))
        {
            using (process)
            {
                try
                {
                    if (string.Equals(Path.GetFullPath(process.MainModule?.FileName ?? string.Empty), expected, StringComparison.OrdinalIgnoreCase))
                        return true;
                }
                catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    // A protected process cannot be treated as confirmation.
                }
            }
        }
        return false;
    }
}
