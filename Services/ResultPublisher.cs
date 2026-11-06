using System.Text.Json;
using OllamaProcessor.Models;
using RabbitMQ.Client;

namespace OllamaProcessor.Services;

/// <summary>
/// Publishes a <see cref="ResultMessage"/> back to the caller over the default exchange.
/// <list type="bullet">
/// <item><b>Request has <c>reply_to</c></b> (RPC style, e.g. direct reply-to
/// <c>amq.rabbitmq.reply-to</c> or a reply queue the caller declared itself):
/// publish with <c>routingKey == reply_to</c> and <c>correlation_id</c> copied from the
/// request. No queue is declared — the caller owns the reply destination.</item>
/// <item><b>No <c>reply_to</c></b> (legacy): declare a durable queue named after the
/// message id (<c>x-expires</c> = request timeout) and publish there.</item>
/// </list>
/// Owns a dedicated publish channel; publishes are serialized because an IChannel is
/// not safe for concurrent use. The channel has no publisher confirms and publishes are
/// not <c>mandatory</c>: if the reply destination is gone (e.g. the caller timed out and
/// its direct reply-to consumer disappeared) the broker silently drops the reply.
/// </summary>
public sealed class ResultPublisher(RabbitMqConnection connection, ILogger<ResultPublisher> logger)
    : IAsyncDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private IChannel? _channel;

    /// <param name="result">Reply payload.</param>
    /// <param name="replyQueueTimeoutMs">Request timeout; <c>x-expires</c> of the legacy reply queue.</param>
    /// <param name="replyTo">Request's <c>reply_to</c>; null/empty => legacy queue-per-id path.</param>
    /// <param name="correlationId">Request's <c>correlation_id</c>, echoed on the reply (reply_to path).</param>
    /// <param name="cancellationToken">Cancellation.</param>
    public async Task PublishAsync(
        ResultMessage result, int replyQueueTimeoutMs, string? replyTo, string? correlationId,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var channel = await EnsureChannelAsync(cancellationToken);
            await PublishAsync(channel, result, replyQueueTimeoutMs, replyTo, correlationId, logger, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Routing decision + publish on the given channel (unit-testable core).</summary>
    internal static async Task PublishAsync(
        IChannel channel, ResultMessage result, int replyQueueTimeoutMs, string? replyTo, string? correlationId,
        ILogger logger, CancellationToken cancellationToken)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(result, AppJsonContext.Default.ResultMessage);

        if (!string.IsNullOrWhiteSpace(replyTo))
        {
            var replyProps = new BasicProperties
            {
                ContentType = "application/json",
                DeliveryMode = DeliveryModes.Persistent,
                MessageId = result.Id,
                CorrelationId = string.IsNullOrEmpty(correlationId) ? result.Id : correlationId,
            };

            // RPC reply: default exchange, routingKey = reply_to. Nothing is declared:
            // for direct reply-to (amq.rabbitmq.reply-to.*) there is no queue at all, and a
            // named reply queue is the caller's to declare. mandatory=false => a reply whose
            // destination is gone is dropped by the broker instead of returned.
            await channel.BasicPublishAsync(
                exchange: string.Empty,
                routingKey: replyTo,
                mandatory: false,
                basicProperties: replyProps,
                body: body,
                cancellationToken: cancellationToken);

            logger.LogInformation("Published result for id={Id} to reply_to '{ReplyTo}' (correlation_id={CorrelationId})",
                result.Id, replyTo, replyProps.CorrelationId);
            return;
        }

        // ---- Legacy path (no reply_to): behavior unchanged. ----
        if (replyQueueTimeoutMs <= 0)
            throw new ArgumentOutOfRangeException(nameof(replyQueueTimeoutMs), "Reply queue timeout must be greater than zero.");

        var props = new BasicProperties
        {
            ContentType = "application/json",
            DeliveryMode = DeliveryModes.Persistent,
            MessageId = result.Id,
        };

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
