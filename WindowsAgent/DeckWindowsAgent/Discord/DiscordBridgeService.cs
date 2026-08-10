using DeckWindowsAgent.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace DeckWindowsAgent.Discord;

/// <summary>Owns the <see cref="DiscordRpcClient"/> lifecycle for the process. Stays idle (never opens the
/// pipe) when Discord isn't configured, so the feature is opt-in and never blocks agent startup.</summary>
public sealed class DiscordBridgeService : IHostedService, IAsyncDisposable
{
    private readonly AgentOptions _options;
    private readonly DiscordTokenStore _tokenStore;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<DiscordBridgeService> _logger;
    private CancellationTokenSource? _lifetime;
    private Task? _runTask;

    public DiscordRpcClient? Client { get; private set; }
    public bool IsConfigured => !string.IsNullOrWhiteSpace(_options.DiscordClientId) && !string.IsNullOrWhiteSpace(_options.DiscordClientSecret);

    public event Action? StateChanged;

    public DiscordBridgeService(
        AgentOptions options,
        DiscordTokenStore tokenStore,
        IHttpClientFactory httpClientFactory,
        ILoggerFactory loggerFactory)
    {
        _options = options;
        _tokenStore = tokenStore;
        _httpClientFactory = httpClientFactory;
        _loggerFactory = loggerFactory;
        _logger = loggerFactory.CreateLogger<DiscordBridgeService>();
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        if (!IsConfigured)
        {
            _logger.LogInformation("Discord bridge is not configured (Agent:DiscordClientId / Agent:DiscordClientSecret are blank); the Discord widget will stay unavailable.");
            return Task.CompletedTask;
        }

        _lifetime = new CancellationTokenSource();
        var client = new DiscordRpcClient(
            _options.DiscordClientId,
            _options.DiscordClientSecret,
            _tokenStore,
            _httpClientFactory.CreateClient("discord-oauth"),
            _loggerFactory.CreateLogger<DiscordRpcClient>());
        client.StateChanged += RaiseStateChanged;
        Client = client;
        _runTask = client.RunAsync(_lifetime.Token);
        return Task.CompletedTask;
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        _lifetime?.Cancel();
        if (_runTask is not null)
        {
            try { await _runTask; }
            catch (Exception error) { _logger.LogDebug(error, "Discord bridge run loop ended while stopping."); }
        }
        if (Client is not null)
        {
            Client.StateChanged -= RaiseStateChanged;
            await Client.DisposeAsync();
        }
    }

    private void RaiseStateChanged() => StateChanged?.Invoke();

    public async ValueTask DisposeAsync() => await StopAsync(CancellationToken.None);
}
