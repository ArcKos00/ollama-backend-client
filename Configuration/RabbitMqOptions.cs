using System.ComponentModel.DataAnnotations;

namespace OllamaProcessor.Configuration;

public sealed class RabbitMqOptions
{
    public const string SectionName = "RabbitMq";

    [Required] public string HostName { get; set; } = "localhost";
    public int Port { get; set; } = 5672;
    public string UserName { get; set; } = "guest";
    public string Password { get; set; } = "guest";
    public string VirtualHost { get; set; } = "/";

    /// <summary>Queue the worker consumes incoming {id,text} messages from.</summary>
    [Required] public string RequestQueue { get; set; } = "ollama-requests";

    /// <summary>How many unacknowledged messages a consumer may hold (concurrency throttle).</summary>
    public ushort PrefetchCount { get; set; } = 4;
}
