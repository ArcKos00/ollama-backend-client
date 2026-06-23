using Microsoft.Extensions.Options;
using OllamaProcessor;
using OllamaProcessor.Configuration;
using OllamaProcessor.Services;
using OllamaSharp;

var builder = Host.CreateApplicationBuilder(args);

builder.Services
    .AddOptions<RabbitMqOptions>()
    .Bind(builder.Configuration.GetSection(RabbitMqOptions.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();

builder.Services
    .AddOptions<OllamaOptions>()
    .Bind(builder.Configuration.GetSection(OllamaOptions.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();

// Shared connection + publisher live for the process lifetime.
builder.Services.AddSingleton<RabbitMqConnection>();
builder.Services.AddSingleton<ResultPublisher>();

// Named HttpClient for Ollama; base address + timeout come from options.
builder.Services.AddHttpClient("ollama", (sp, http) =>
{
    var options = sp.GetRequiredService<IOptions<OllamaOptions>>().Value;
    http.BaseAddress = new Uri(options.BaseUrl);
    http.Timeout = options.Timeout;
});

// OllamaSharp client over that HttpClient, with the configured model selected.
builder.Services.AddSingleton<IOllamaApiClient>(sp =>
{
    var http = sp.GetRequiredService<IHttpClientFactory>().CreateClient("ollama");
    var options = sp.GetRequiredService<IOptions<OllamaOptions>>().Value;
    return new OllamaApiClient(http, options.Model);
});

builder.Services.AddSingleton<OllamaClient>();

builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
