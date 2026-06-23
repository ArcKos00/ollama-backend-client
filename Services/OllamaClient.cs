using OllamaSharp;
using OllamaSharp.Models;

namespace OllamaProcessor.Services;

/// <summary>Outcome of a generation, decoupled from OllamaSharp's stream types.</summary>
public sealed record OllamaResult(string Response, string Model);

/// <summary>
/// Wraps OllamaSharp's <see cref="IOllamaApiClient"/>. The model is the client's
/// configured <c>SelectedModel</c>; we stream and consolidate into one result.
/// </summary>
public sealed class OllamaClient(IOllamaApiClient client, ILogger<OllamaClient> logger)
{
    public async Task<OllamaResult> GenerateAsync(
        string prompt, double temperature, string? system, CancellationToken cancellationToken)
    {
        var request = new GenerateRequest
        {
            Model = client.SelectedModel,
            Prompt = prompt,
            System = system,
            Stream = true,
            Options = new RequestOptions { Temperature = (float)temperature },
        };

        logger.LogDebug(
            "Generating via Ollama (model={Model}, temperature={Temp}, hasSystem={HasSystem}, promptLength={Len})",
            client.SelectedModel, temperature, system is not null, prompt.Length);

        // Stream the chunks and consolidate them into a single done-response.
        var final = await client.GenerateAsync(request, cancellationToken).StreamToEndAsync();

        return new OllamaResult(
            Response: final?.Response ?? string.Empty,
            Model: final?.Model ?? client.SelectedModel ?? string.Empty);
    }
}
