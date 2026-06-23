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

## Send a test message

From the RabbitMQ management UI (http://localhost:15672, guest/guest), publish to the
`ollama-requests` queue with payload:

```json
{ "id": "demo-1", "text": "Say hello in one short sentence." }
```

Then watch the `demo-1` queue — the response appears there.
