using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using OllamaProcessor.Configuration;
using OllamaProcessor.Models;
using OllamaProcessor.Services;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace OllamaProcessor;

public sealed class Worker(
    RabbitMqConnection connection,
    ResultPublisher publisher,
    OllamaClient ollama,
    IOptions<RabbitMqOptions> rabbitOptions,
    IOptions<OllamaOptions> ollamaOptions,
    ILogger<Worker> logger) : BackgroundService
{
    private readonly RabbitMqOptions _rabbit = rabbitOptions.Value;
    private readonly OllamaOptions _ollama = ollamaOptions.Value;
    private IChannel? _channel;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var conn = await connection.GetConnectionAsync(stoppingToken);
        _channel = await conn.CreateChannelAsync(cancellationToken: stoppingToken);

        await _channel.QueueDeclareAsync(
            queue: _rabbit.RequestQueue, durable: true, exclusive: false, autoDelete: false,
            arguments: null, cancellationToken: stoppingToken);

        // Limit how many messages we hold unacked => bounds concurrency against Ollama.
        await _channel.BasicQosAsync(0, _rabbit.PrefetchCount, global: false, stoppingToken);

        var consumer = new AsyncEventingBasicConsumer(_channel);
        consumer.ReceivedAsync += OnMessageAsync;

        await _channel.BasicConsumeAsync(
            queue: _rabbit.RequestQueue, autoAck: false, consumer: consumer,
            cancellationToken: stoppingToken);

        logger.LogInformation("Listening for messages on '{Queue}' (prefetch={Prefetch})",
            _rabbit.RequestQueue, _rabbit.PrefetchCount);

        // Keep the service alive until shutdown is requested.
        try
        {
            await Task.Delay(Timeout.Infinite, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown.
        }
    }

    private async Task OnMessageAsync(object sender, BasicDeliverEventArgs ea)
    {
        var channel = _channel!;
        var deliveryTag = ea.DeliveryTag;

        IncomingMessage? message;
        try
        {
            message = JsonSerializer.Deserialize(ea.Body.Span, AppJsonContext.Default.IncomingMessage);
        }
        catch (JsonException ex)
        {
            logger.LogError(ex, "Discarding malformed message (deliveryTag={Tag})", deliveryTag);
            await channel.BasicRejectAsync(deliveryTag, requeue: false);
            return;
        }

        if (message is null || string.IsNullOrWhiteSpace(message.Id))
        {
            logger.LogError("Discarding message with no id (deliveryTag={Tag})", deliveryTag);
            await channel.BasicRejectAsync(deliveryTag, requeue: false);
            return;
        }

        try
        {
            logger.LogInformation("Processing id={Id}", message.Id);

            var generation = await ollama.GenerateAsync(message.Text, CancellationToken.None);

            var result = new ResultMessage(
                Id: message.Id,
                Response: generation.Response ?? string.Empty,
                Model: generation.Model ?? _ollama.Model);

            await publisher.PublishAsync(result, CancellationToken.None);
            await channel.BasicAckAsync(deliveryTag, multiple: false);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to process id={Id}; publishing error result", message.Id);

            // Surface the failure to the caller's reply queue, then ack so it doesn't loop.
            var errorResult = new ResultMessage(
                Id: message.Id, Response: string.Empty, Model: _ollama.Model, Error: ex.Message);

            try
            {
                await publisher.PublishAsync(errorResult, CancellationToken.None);
                await channel.BasicAckAsync(deliveryTag, multiple: false);
            }
            catch (Exception publishEx)
            {
                logger.LogError(publishEx, "Could not publish error result for id={Id}; requeueing", message.Id);
                await channel.BasicNackAsync(deliveryTag, multiple: false, requeue: true);
            }
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_channel is not null)
            await _channel.DisposeAsync();
        await base.StopAsync(cancellationToken);
    }
}
