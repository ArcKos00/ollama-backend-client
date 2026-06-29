using System.Text.Json;
using OllamaProcessor.Models;
using RabbitMQ.Client;

namespace OllamaProcessor.Services;

/// <summary>
/// Publishes a <see cref="ResultMessage"/> to a queue named after the message id,
/// using the default exchange (routingKey == queue name). Owns a dedicated publish
/// channel; publishes are serialized because an IChannel is not safe for concurrent use.
/// </summary>
public sealed class ResultPublisher(RabbitMqConnection connection, ILogger<ResultPublisher> logger)
    : IAsyncDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private IChannel? _channel;

    public async Task PublishAsync(ResultMessage result, int replyQueueTimeoutMs, CancellationToken cancellationToken)
    {
        if (replyQueueTimeoutMs <= 0)
            throw new ArgumentOutOfRangeException(nameof(replyQueueTimeoutMs), "Reply queue timeout must be greater than zero.");

        var body = JsonSerializer.SerializeToUtf8Bytes(result, AppJsonContext.Default.ResultMessage);

        var props = new BasicProperties
        {
            ContentType = "application/json",
            DeliveryMode = DeliveryModes.Persistent,
            MessageId = result.Id,
        };

        await _gate.WaitAsync(cancellationToken);
        try
        {
            var channel = await EnsureChannelAsync(cancellationToken);

            // Declare the reply queue (idempotent) so it exists even with no consumer yet.
            var queueArguments = new Dictionary<string, object?>
            {
                ["x-expires"] = replyQueueTimeoutMs
            };

            await channel.QueueDeclareAsync(
                queue: result.Id, durable: true, exclusive: false, autoDelete: false,
                arguments: queueArguments, cancellationToken: cancellationToken);

            // Default exchange ("") routes by routingKey straight to the queue of that name.
            await channel.BasicPublishAsync(
                exchange: string.Empty,
                routingKey: result.Id,
                mandatory: false,
                basicProperties: props,
                body: body,
                cancellationToken: cancellationToken);

            logger.LogInformation("Published result for id={Id} to queue '{Queue}'", result.Id, result.Id);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<IChannel> EnsureChannelAsync(CancellationToken cancellationToken)
    {
        if (_channel is { IsOpen: true })
            return _channel;

        var conn = await connection.GetConnectionAsync(cancellationToken);
        _channel = await conn.CreateChannelAsync(cancellationToken: cancellationToken);
        return _channel;
    }

    public async ValueTask DisposeAsync()
    {
        if (_channel is not null)
            await _channel.DisposeAsync();
        _gate.Dispose();
    }
}
