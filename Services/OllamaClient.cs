using OllamaSharp;
using OllamaSharp.Models;

namespace OllamaProcessor.Services;

/// <summary>Outcome of a generation, decoupled from OllamaSharp's stream types.</summary>
public sealed record OllamaResult(string Response, string Model);

/// <summary>
/// Wraps OllamaSharp's <see cref="IOllamaApiClient"/>. The model is the client's
/// configured <c>SelectedModel</c>. We don't emit partial tokens, so we request a
/// single (non-streamed) response and read it directly.
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
            Stream = false,
            Options = new RequestOptions { Temperature = (float)temperature },
        };

        logger.LogInformation(
            "Ollama generate starting (model={Model}, temperature={Temp}, hasSystem={HasSystem}, promptLength={Len})",
            client.SelectedModel, temperature, system is not null, prompt.Length);

        // Non-streamed: a single response chunk is returned when generation completes.
        var final = await client.GenerateAsync(request, cancellationToken).StreamToEndAsync();

        logger.LogInformation("Ollama generate finished (responseLength={Len})",
            final?.Response?.Length ?? 0);

        return new OllamaResult(
            Response: final?.Response ?? string.Empty,
            Model: final?.Model ?? client.SelectedModel ?? string.Empty);
    }
}
