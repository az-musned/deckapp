namespace DeckWindowsAgent.Power;

/// Runs the PC's own delayed-sleep timer for the "Sleep Timer" feature, so it fires reliably
/// regardless of whether the phone that requested it is still open, foregrounded, or even
/// reachable by the time the delay elapses -- unlike the phone-side countdown (a plain
/// in-process Task) it replaces for the PC target, this doesn't depend on iOS's background
/// execution limits at all. Single global schedule: a new request replaces whatever was
/// previously pending, since "sleep the PC once, at some point" is the only use case -- there's
/// no notion of multiple concurrent sleep timers.
public sealed class ScheduledSleepService(ILogger<ScheduledSleepService> logger) : IDisposable
{
    private readonly object _gate = new();
    private CancellationTokenSource? _pending;

    /// True while a sleep is scheduled and hasn't fired or been cancelled yet.
    public bool IsScheduled
    {
        get { lock (_gate) { return _pending is not null; } }
    }

    public void Schedule(TimeSpan delay)
    {
        var cancellation = new CancellationTokenSource();
        CancellationTokenSource? previous;
        lock (_gate)
        {
            previous = _pending;
            _pending = cancellation;
        }
        // Cancel outside the lock -- Cancel() can synchronously run continuations, and doing
        // that while holding _gate risks deadlocking against another thread also waiting on it.
        previous?.Cancel();
        previous?.Dispose();

        var token = cancellation.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(delay, token);
            }
            catch (TaskCanceledException)
            {
                return;
            }

            lock (_gate)
            {
                // Only clear if this is still the current schedule -- a newer Schedule() call
                // (or Cancel()) may have already replaced/cleared it.
                if (_pending == cancellation) _pending = null;
            }

            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "rundll32.exe",
                    Arguments = "powrprof.dll,SetSuspendState 0,1,0",
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
                logger.LogInformation("Scheduled sleep timer fired -- suspending.");
            }
            catch (Exception error)
            {
                logger.LogWarning("Scheduled sleep timer fired but SetSuspendState failed: {Message}", error.Message);
            }
        }, CancellationToken.None);
    }

    /// Returns whether anything was actually cancelled.
    public bool Cancel()
    {
        CancellationTokenSource? previous;
        lock (_gate)
        {
            previous = _pending;
            _pending = null;
        }
        if (previous is null) return false;
        previous.Cancel();
        previous.Dispose();
        return true;
    }

    public void Dispose() => Cancel();
}
