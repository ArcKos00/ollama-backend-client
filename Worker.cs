using System.Text;
using System.Text.Json;
using Elastic.Apm;
using Elastic.Apm.Api;
using Microsoft.Extensions.Options;
using Microsoft.VisualBasic;
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
    private const int MaxTraceTextLength = 1000;

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

        var msg = message; // non-null past the guard; captured by the trace delegate

        // Continue the caller's distributed trace: prefer the AMQP header, fall back to the
        // traceparent carried in the message body. Null => start a fresh root transaction.
        var tracingData = ExtractDistributedTracingData(ea, msg);

        // One APM transaction per message; the Ollama call is a child span that carries
        // the request prompt and the generated response for end-to-end tracing.
        await Agent.Tracer.CaptureTransaction("process-message", "messaging", async transaction =>
        {
            transaction.SetLabel("message.id", msg.Id);
            transaction.SetLabel("ollama.model", _ollama.Model);
            transaction.SetLabel("ollama.temperature", msg.Temperature);
            transaction.SetLabel("request.text", Truncate(msg.Text));
            transaction.SetLabel("request.timeout", msg.Timeout);
            
            if (!string.IsNullOrEmpty(msg.System))
                transaction.SetLabel("request.system", Truncate(msg.System));

            try
            {
                logger.LogInformation("Processing id={Id}", msg.Id);

                var generation = await transaction.CaptureSpan(
                    "ollama generate", "external",
                    async span =>
                    {
                        var g = await ollama.GenerateAsync(
                            msg.Text, msg.Temperature, msg.System, CancellationToken.None);
                        span.SetLabel("response.text", Truncate(g.Response));
                        span.SetLabel("response.length", g.Response.Length);
                        return g;
                    },
                    subType: "ollama", action: "generate");

                var result = new ResultMessage(
                    Id: msg.Id,
                    Response: generation.Response ?? string.Empty,
                    Model: generation.Model ?? _ollama.Model);

                await publisher.PublishAsync(result, msg.Timeout, CancellationToken.None);
                await channel.BasicAckAsync(deliveryTag, multiple: false);
            }
            catch (Exception ex)
            {
                transaction.CaptureException(ex);
                transaction.Outcome = Outcome.Failure;
                logger.LogError(ex, "Failed to process id={Id}; publishing error result", msg.Id);

                // Surface the failure to the caller's reply queue, then ack so it doesn't loop.
                var errorResult = new ResultMessage(
                    Id: msg.Id, Response: string.Empty, Model: _ollama.Model, Error: ex.Message);

                try
                {
                    await publisher.PublishAsync(errorResult, msg.Timeout, CancellationToken.None);
                    await channel.BasicAckAsync(deliveryTag, multiple: false);
                }
                catch (Exception publishEx)
                {
                    logger.LogError(publishEx, "Could not publish error result for id={Id}; requeueing", msg.Id);
                    await channel.BasicNackAsync(deliveryTag, multiple: false, requeue: true);
                }
            }
        }, tracingData);
    }

    // W3C header used to propagate the trace across the message boundary.
    private const string TraceParentHeader = "traceparent";

    /// <summary>
    /// Resolves the incoming <c>traceparent</c> so this transaction joins the caller's trace.
    /// AMQP headers win over the message body; returns <c>null</c> when nothing usable is present,
    /// which makes <see cref="ITracer.CaptureTransaction"/> begin a new root transaction.
    /// </summary>
    private DistributedTracingData? ExtractDistributedTracingData(BasicDeliverEventArgs ea, IncomingMessage message)
    {
        var traceParent = ReadHeader(ea, TraceParentHeader);
        if (string.IsNullOrWhiteSpace(traceParent))
            traceParent = message.Traceparent;

        if (string.IsNullOrWhiteSpace(traceParent))
            return null;

        var tracingData = DistributedTracingData.TryDeserializeFromString(traceParent);
        if (tracingData is null)
            logger.LogWarning("Ignoring malformed traceparent '{TraceParent}' for id={Id}", traceParent, message.Id);

        return tracingData;
    }

    /// <summary>Reads an AMQP header as a string; header values arrive as UTF-8 <c>byte[]</c>.</summary>
    private static string? ReadHeader(BasicDeliverEventArgs ea, string name)
    {
        if (ea.BasicProperties.Headers is not { } headers || !headers.TryGetValue(name, out var value))
            return null;

        return value switch
        {
            byte[] bytes => Encoding.UTF8.GetString(bytes),
            string s => s,
            _ => value?.ToString(),
        };
    }

    private static string Truncate(string value) =>
        value.Length <= MaxTraceTextLength ? value : value[..MaxTraceTextLength];

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_channel is not null)
            await _channel.DisposeAsync();
        await base.StopAsync(cancellationToken);
    }
}



