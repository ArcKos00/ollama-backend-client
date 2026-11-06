using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;
using OllamaProcessor.Models;
using OllamaProcessor.Services;
using RabbitMQ.Client;

namespace OllamaProcessor.Tests;

public sealed class ResultPublisherTests
{
    private static readonly ResultMessage Result = new(Id: "0193-msg-id", Response: "{\"ok\":true}", Model: "llama3:8b");

    private sealed record Published(string Exchange, string RoutingKey, bool Mandatory, BasicProperties Props, byte[] Body);

    private static Published SinglePublish(IChannel channel)
    {
        var call = Assert.Single(channel.ReceivedCalls(), c => c.GetMethodInfo().Name == nameof(IChannel.BasicPublishAsync));
        var a = call.GetArguments();
        return new Published((string)a[0]!, (string)a[1]!, (bool)a[2]!, (BasicProperties)a[3]!,
            ((ReadOnlyMemory<byte>)a[4]!).ToArray());
    }

    private static bool AnyQueueDeclare(IChannel channel) =>
        channel.ReceivedCalls().Any(c => c.GetMethodInfo().Name == nameof(IChannel.QueueDeclareAsync));

    private static Task Publish(IChannel channel, string? replyTo, string? correlationId, int timeoutMs = 900_000) =>
        ResultPublisher.PublishAsync(channel, Result, timeoutMs, replyTo, correlationId,
            NullLogger.Instance, CancellationToken.None);

    [Theory]
    [InlineData("amq.rabbitmq.reply-to.g1h2AA5yZXBseUAxMjM0NTY3OAAAAAAAAAAB.abc==")] // direct reply-to (rewritten by broker)
    [InlineData("0193-msg-id")] // legacy parser: reply queue it declared itself
    public async Task ReplyTo_set_publishes_to_reply_to_without_declaring_a_queue(string replyTo)
    {
        var channel = Substitute.For<IChannel>();

        await Publish(channel, replyTo, correlationId: "corr-42");

        Assert.False(AnyQueueDeclare(channel));
        var p = SinglePublish(channel);
        Assert.Equal(string.Empty, p.Exchange);
        Assert.Equal(replyTo, p.RoutingKey);
        Assert.False(p.Mandatory);
        Assert.Equal("corr-42", p.Props.CorrelationId);
        Assert.Equal("application/json", p.Props.ContentType);
        Assert.Equal(Result.Id, p.Props.MessageId);
    }

    [Fact]
    public async Task ReplyTo_set_body_is_the_same_json_contract()
    {
        var channel = Substitute.For<IChannel>();

        await Publish(channel, "amq.rabbitmq.reply-to.x", "corr-1");

        using var doc = JsonDocument.Parse(SinglePublish(channel).Body);
        Assert.Equal(Result.Id, doc.RootElement.GetProperty("id").GetString());
        Assert.Equal(Result.Response, doc.RootElement.GetProperty("response").GetString());
        Assert.Equal(Result.Model, doc.RootElement.GetProperty("model").GetString());
        Assert.False(doc.RootElement.TryGetProperty("error", out _));
    }

    [Fact]
    public async Task ReplyTo_set_without_correlation_id_falls_back_to_message_id()
    {
        var channel = Substitute.For<IChannel>();

        await Publish(channel, "amq.rabbitmq.reply-to.x", correlationId: null);

        Assert.Equal(Result.Id, SinglePublish(channel).Props.CorrelationId);
    }

    [Fact]
    public async Task ReplyTo_set_does_not_require_a_positive_timeout()
    {
        var channel = Substitute.For<IChannel>();

        await Publish(channel, "amq.rabbitmq.reply-to.x", "c", timeoutMs: 0);

        Assert.Equal("amq.rabbitmq.reply-to.x", SinglePublish(channel).RoutingKey);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public async Task ReplyTo_empty_keeps_legacy_queue_named_after_id(string? replyTo)
    {
        var channel = Substitute.For<IChannel>();

        await Publish(channel, replyTo, correlationId: "corr-42", timeoutMs: 123_456);

        await channel.Received(1).QueueDeclareAsync(
            Result.Id, Arg.Is(true), Arg.Is(false), Arg.Is(false),
            Arg.Is<IDictionary<string, object?>>(d =>
                d.Count == 1 && d["x-expires"] is int && (int)d["x-expires"]! == 123_456),
            Arg.Any<bool>(), Arg.Any<bool>(), Arg.Any<CancellationToken>());

        var p = SinglePublish(channel);
        Assert.Equal(string.Empty, p.Exchange);
        Assert.Equal(Result.Id, p.RoutingKey);
        Assert.False(p.Mandatory);
        Assert.Null(p.Props.CorrelationId); // legacy props unchanged
        Assert.Equal(Result.Id, p.Props.MessageId);
        Assert.Equal(DeliveryModes.Persistent, p.Props.DeliveryMode);
    }

    [Fact]
    public async Task ReplyTo_empty_with_non_positive_timeout_still_throws()
    {
        var channel = Substitute.For<IChannel>();

        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => Publish(channel, null, null, timeoutMs: 0));
        Assert.Empty(channel.ReceivedCalls());
    }
}
