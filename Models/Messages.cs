using System.Text.Json.Serialization;

namespace OllamaProcessor.Models;

/// <summary>
/// Incoming work item read from the request queue:
/// {"id":..., "text":..., "temperature":..., "system":...}.
/// <c>temperature</c> and <c>system</c> are optional; absent values use the defaults below.
/// </summary>
public sealed record IncomingMessage(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("temperature")] double Temperature = 1.0,
    [property: JsonPropertyName("system")] string? System = null,
    [property: JsonPropertyName("timeout")] int Timeout = 1000);

/// <summary>Result published to the per-message reply queue (queue name == message id).</summary>
public sealed record ResultMessage(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("response")] string Response,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("error")] string? Error = null);

/// <summary>Source-generated JSON context for fast, trim/AOT-friendly (de)serialization.</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(IncomingMessage))]
[JsonSerializable(typeof(ResultMessage))]
public sealed partial class AppJsonContext : JsonSerializerContext;
