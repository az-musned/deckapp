using System.Net;
using DeckWindowsAgent.Capabilities;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Input;
using DeckWindowsAgent.Protocol;
using DeckWindowsAgent.Safety;
using DeckWindowsAgent.Security;
using DeckWindowsAgent.Transport;

var builder = WebApplication.CreateBuilder(args);
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: false);
var options = builder.Configuration.GetSection("Agent").Get<AgentOptions>() ?? new AgentOptions();
options.Validate();
var certificate = CertificateLoader.LoadCurrentUserCertificate(options.CertificateThumbprint);

builder.WebHost.ConfigureKestrel(server =>
{
    foreach (var address in options.EffectiveBindAddresses)
    {
        server.Listen(IPAddress.Parse(address), options.Port, listen => listen.UseHttps(certificate));
    }
    server.Limits.MaxRequestBodySize = 16 * 1024;
    server.Limits.MaxConcurrentUpgradedConnections = 1;
});

var dataDirectory = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
    "DeckWindowsAgent");
builder.Services.AddSingleton(options);
builder.Services.AddSingleton(new PairingStore(Path.Combine(dataDirectory, "paired-devices.json")));
builder.Services.AddSingleton<PairingService>();
builder.Services.AddSingleton<AgentSafetyState>();
builder.Services.AddSingleton<InputSessionRegistry>();
builder.Services.AddSingleton<IWindowsInputSink, WindowsSendInputSink>();
builder.Services.AddSingleton<IApplicationCapabilityService, ApplicationCapabilityService>();
builder.Services.AddSingleton<IWindowsAudioSessionService, WindowsAudioSessionService>();
builder.Services.AddSingleton<IGoXlrCapabilityService, GoXlrCapabilityService>();
builder.Services.AddSingleton<IAgentCapabilityService, AgentCapabilityService>();
builder.Services.AddHostedService<LocalSafetyConsoleService>();

var app = builder.Build();
app.UseWebSockets(new WebSocketOptions
{
    KeepAliveInterval = TimeSpan.FromSeconds(20),
    KeepAliveTimeout = TimeSpan.FromSeconds(20)
});

app.Use(async (context, next) =>
{
    var remoteAddress = context.Connection.RemoteIpAddress;
    if (remoteAddress is null || !PrivateNetworkGuard.IsPrivateOrLoopback(remoteAddress))
    {
        context.Response.StatusCode = StatusCodes.Status403Forbidden;
        return;
    }
    context.Response.Headers["Cache-Control"] = "no-store";
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    await next();
});

app.MapGet("/api/v1/health", () => Results.Ok(new { protocolVersion = PairingService.ProtocolVersion }));

app.MapPost("/api/v1/pairing/start", (PairingStartRequest request, PairingService pairing) =>
{
    try { return Results.Ok(pairing.Start(request)); }
    catch (ArgumentException error) { return Results.BadRequest(new { error = error.Message }); }
    catch (InvalidOperationException error) { return Results.Json(new { error = error.Message }, statusCode: StatusCodes.Status429TooManyRequests); }
});

app.MapPost("/api/v1/pairing/confirm", (PairingConfirmRequest request, PairingService pairing) =>
{
    try { return Results.Ok(pairing.Confirm(request)); }
    catch (UnauthorizedAccessException) { return Results.Unauthorized(); }
});

app.MapGet("/api/v1/agent/security", (
    HttpContext context,
    PairingService pairing,
    AgentSafetyState safety,
    IWindowsInputSink input) =>
{
    if (!TryAuthenticate(context, pairing)) return Results.Unauthorized();
    return Results.Ok(new AgentSecuritySnapshot(
        safety.RemoteInputAllowed,
        safety.EmergencyInputDisabled,
        input.IsAvailable,
        PairingService.ProtocolVersion));
});

app.MapDelete("/api/v1/agent/pairing", (HttpContext context, PairingService pairing) =>
{
    var token = BearerToken(context);
    var device = token is null ? null : pairing.AuthenticateDevice(token);
    if (device is null) return Results.Unauthorized();
    return pairing.Revoke(device.Id) ? Results.NoContent() : Results.NotFound();
});

app.MapGet("/api/v1/agent/capabilities", async (
    HttpContext context,
    PairingService pairing,
    IAgentCapabilityService capabilities,
    CancellationToken cancellationToken) =>
{
    if (!TryAuthenticate(context, pairing)) return Results.Unauthorized();
    return Results.Ok(await capabilities.SnapshotAsync(cancellationToken));
});

app.MapPost("/api/v1/agent/commands", async (
    HttpContext context,
    AgentCapabilityCommandRequest request,
    PairingService pairing,
    IAgentCapabilityService capabilities,
    CancellationToken cancellationToken) =>
{
    if (!TryAuthenticate(context, pairing)) return Results.Unauthorized();
    try { return Results.Ok(await capabilities.ExecuteAsync(request, cancellationToken)); }
    catch (CapabilityUnavailableException error)
    {
        return Results.Json(new { error = error.Message }, statusCode: StatusCodes.Status409Conflict);
    }
});

app.MapInputWebSocket();

app.Run();

static bool TryAuthenticate(HttpContext context, PairingService pairing)
{
    var token = BearerToken(context);
    return token is not null && pairing.Authenticate(token);
}

static string? BearerToken(HttpContext context)
{
    var authorization = context.Request.Headers["Authorization"].ToString();
    const string prefix = "Bearer ";
    return authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
        ? authorization[prefix.Length..].Trim()
        : null;
}
