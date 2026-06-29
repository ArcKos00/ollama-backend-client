using System.ComponentModel.DataAnnotations;

namespace OllamaProcessor.Configuration;

public sealed class OllamaOptions
{
    public const string SectionName = "Ollama";

    /// <summary>Base URL of the Ollama service, e.g. http://localhost:11434.</summary>
    [Required]
    public string BaseUrl { get; set; } = "http://localhost:11434";

    /// <summary>Model to run, e.g. "llama3.2".</summary>
    [Required]
    public string Model { get; set; } = "llama3.2";

    /// <summary>Per-request timeout. Generation can be slow, so default high.</summary>
    public TimeSpan Timeout { get; set; } = TimeSpan.FromMinutes(5);
}
