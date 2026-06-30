# OllamaProcessor

A .NET 10 Worker Service that processes work asynchronously:

1. Consumes `{ "id": ..., "text": ... }` messages from a RabbitMQ request queue.
2. Sends `text` to an Ollama service using the [OllamaSharp](https://github.com/awaescher/OllamaSharp) client (`/api/generate`, streamed and consolidated).
3. Publishes the result to a reply queue **named after the message `id`** (default exchange, `routingKey == id`).

```
RabbitMQ (ollama-requests)  ─►  Worker  ─►  Ollama /api/generate
                                   │
                                   └─►  RabbitMQ (queue == message id)
```

## Configuration

Set in `appsettings.json`, or override with environment variables (e.g. `Ollama__Model=llama3.2`, `RabbitMq__HostName=...`).

> **Secrets:** `appsettings.json` holds non-secret defaults only and is committed. Real
> credentials/hosts go in `appsettings.Development.json` (gitignored) for local dev, or via
> environment variables / a secret store in production. `dotnet run` loads the Development
> environment by default (see `Properties/launchSettings.json`).

| Section  | Key            | Default                  | Notes                                      |
|----------|----------------|--------------------------|--------------------------------------------|
| RabbitMq | HostName       | `localhost`              |                                            |
| RabbitMq | Port           | `5672`                   |                                            |
| RabbitMq | UserName       | `guest`                  |                                            |
| RabbitMq | Password       | `guest`                  |                                            |
| RabbitMq | RequestQueue   | `ollama-requests`        | Queue the worker consumes                  |
| RabbitMq | PrefetchCount  | `4`                      | Max in-flight messages (concurrency throttle) |
| Ollama   | BaseUrl        | `http://localhost:11434` |                                            |
| Ollama   | Model          | `llama3.2`               | Must be pulled in Ollama                   |
| Ollama   | Timeout        | `00:05:00`               | Per-request HTTP timeout                   |

## Run

Prerequisites: a running RabbitMQ and a running Ollama with the model pulled (`ollama pull llama3.2`).

```bash
# quick local infra
docker run -d --name rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:3-management

dotnet run
```

## Behavior notes

- **Result queue:** declared durable and named after the `id`; the result body is
  `{ "id", "response", "model", "error" }`. On Ollama failure an `error` result is still
  published so the caller never hangs.
- **Acking:** success and handled-error messages are acked. Malformed messages (bad JSON
  or missing id) are rejected without requeue. If publishing the result itself fails, the
  message is requeued.
- **Concurrency:** bounded by `PrefetchCount`. Publishing is serialized over a dedicated
  channel (an `IChannel` is not safe for concurrent use).
- **Ollama:** via OllamaSharp's `IOllamaApiClient`, built over a named `HttpClient` (base URL +
  timeout from options) with `SelectedModel` set to `Ollama:Model`. Responses are streamed and
  consolidated with `StreamToEndAsync()`.
- **JSON:** queue messages use `System.Text.Json` source generation (`AppJsonContext`) — trim/AOT friendly.

## Observability (Elastic APM)

Each consumed message becomes an APM **transaction** (`process-message`, type `messaging`). The
Ollama call is a child **span** (`ollama generate`), and the outgoing HTTP request is auto-captured
via `HttpDiagnosticsSubscriber`. Request/response content is traced as labels:

| Where       | Label                | Value                                  |
|-------------|----------------------|----------------------------------------|
| transaction | `message.id`         | message id                             |
| transaction | `ollama.model`       | configured model                       |
| transaction | `ollama.temperature` | requested temperature                  |
| transaction | `request.text`       | prompt (truncated to 1000 chars)       |
| transaction | `request.system`     | system prompt, if provided (truncated) |
| span        | `response.text`      | generated text (truncated to 1000)     |
| span        | `response.length`    | full response length                   |

Failures call `CaptureException` and mark the transaction outcome as failed.

Configure via the `ElasticApm` section (or `ELASTIC_APM_*` env vars):

```jsonc
"ElasticApm": {
  "ServiceName": "ollama-backend-client",
  "Environment": "production",
  "ServerUrl": "http://localhost:8200",
  "SecretToken": "",
  "TransactionSampleRate": 1.0,
  "Enabled": true        // set false to disable the agent entirely
}
```

## Send a test message

From the RabbitMQ management UI (http://localhost:15672, guest/guest), publish to the
`ollama-requests` queue with payload:

```json
{
  "id": "demo-1",
  "text": "Say hello in one short sentence.",
  "temperature": 1.0,
  "system": "You are a terse assistant.",
  "timeout": 100000
}
```

`temperature` (default `1.0`) and `system` are optional — omit them to use the defaults.

Then watch the `demo-1` queue — the response appears there.
