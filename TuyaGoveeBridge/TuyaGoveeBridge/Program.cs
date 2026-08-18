using TuyaGoveeBridge.Configuration;
using TuyaGoveeBridge.Govee;
using TuyaGoveeBridge.Tuya;

var builder = Host.CreateApplicationBuilder(args);
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: false);

var options = builder.Configuration.GetSection("Bridge").Get<BridgeOptions>() ?? new BridgeOptions();
options.Validate();

builder.Services.AddSingleton(options);
builder.Services.AddHttpClient();
builder.Services.AddSingleton<GoveeClient>();
builder.Services.AddHostedService<TuyaButtonBridgeService>();

var app = builder.Build();
app.Run();
