using System.Text.Json.Serialization;

namespace OllamaProcessor.Models;

/// <summary>
/// Incoming work item read from the request queue:
/// {"id":..., "text":..., "temperature":..., "system":..., "traceparent":...}.
/// <c>temperature</c>, <c>system</c> and <c>traceparent</c> are optional; absent values use the defaults below.
/// <c>traceparent</c> is a W3C trace-context value used to continue the caller's distributed trace
/// when it is not supplied via the AMQP message headers.
/// </summary>
public sealed record IncomingMessage(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("temperature")] double Temperature = 1.0,
    [property: JsonPropertyName("system")] string? System = null,
    [property: JsonPropertyName("timeout")] int Timeout = 1000,
    [property: JsonPropertyName("traceparent")] string Traceparent = ""
    );

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
