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

## Deployment (Docker Compose)

`docker-compose.yaml` brings up three services:

| Service | Purpose |
|---------|---------|
| `ollama` | The Ollama runtime (`host` networking, NVIDIA GPU reservation, `ollama` volume). |
| `ollama-model-puller` | One-shot: waits ~10s, then `POST /api/pull` for the model, then exits. |
| `ollama-backend-client` | This worker; built from `Dockerfile`, configured via `environment:`. |

> The compose file is **Linux-oriented**: `network_mode: host` and the `nvidia` GPU
> reservation don't map cleanly onto Docker Desktop for Windows/macOS. The intended
> target is a Linux host with the NVIDIA Container Toolkit installed.

First bring-up (once, by hand):

```bash
docker compose up -d --build
```

## Auto-update on new commits

Two role-based scripts keep a deployed checkout in sync with `origin` and redeploy on
every new commit. Provided for both Linux and Windows:

| Role | Linux | Windows |
|------|-------|---------|
| **Worker** — one-shot: if `origin/<branch>` has a new commit, `git reset --hard` + full `docker compose` rebuild; otherwise no-op | `update-and-redeploy.sh` | `update-and-redeploy.ps1` |
| **Installer** — registers the worker to run periodically | `install-cron.sh` (cron) | `install-taskscheduler.ps1` (Task Scheduler) |

The worker guards against overlapping runs (`flock` on Linux, a named mutex on Windows),
so a rebuild that outlasts the interval simply skips the next tick. It also sets a sane
`PATH` and `GIT_TERMINAL_PROMPT=0` so it behaves correctly in a non-interactive scheduler
environment.

### Linux

```bash
docker compose up -d --build            # initial bring-up, once
INTERVAL_MINUTES=5 bash install-cron.sh # register the periodic check
crontab -l                              # verify
bash install-cron.sh --uninstall        # remove
```

Runs go to `update-and-redeploy.log` in the repo root (gitignored). Requires an enabled
cron daemon (`systemctl enable --now cron` / `crond`).

### Windows

Run in an **elevated** PowerShell:

```powershell
docker compose up -d --build
.\install-taskscheduler.ps1 -IntervalMinutes 5
.\install-taskscheduler.ps1 -Uninstall   # remove
```

The task triggers `AtLogOn` + repeats every N minutes (Docker Desktop lives in the user
session, so it needs an interactive logon).

> `git reset --hard` is intentional: the deployed tree is made to exactly match
> `origin/<branch>`, discarding any local edits to tracked files. Don't hand-edit tracked
> files on a deploy host.

## Git access on a deploy host

A private repo needs **non-interactive** credentials, or the worker fails with
`could not read Username for 'https://github.com'`. Cloning once is not enough — if no
persistent credential helper was configured, the auth used at clone time is not saved.

Two ways to provide durable credentials (pick one; no script changes needed):

**SSH deploy key** (recommended — no expiry, read-only, scoped to one repo, works under
cron without an agent):

```bash
ssh-keygen -t ed25519 -C "ollama-deploy" -f ~/.ssh/ollama_deploy -N ""
cat ~/.ssh/ollama_deploy.pub    # add on GitHub: repo → Settings → Deploy keys → Add
printf '\nHost github.com\n    IdentityFile ~/.ssh/ollama_deploy\n    IdentitiesOnly yes\n' >> ~/.ssh/config
ssh-keyscan github.com >> ~/.ssh/known_hosts
git remote set-url origin git@github.com:<owner>/<repo>.git
git fetch origin
```

**Personal Access Token via the store helper** (quick; token saved in plaintext):

```bash
git remote set-url origin https://github.com/<owner>/<repo>.git
git config credential.helper store
git fetch origin      # Username: <login>, Password: <PAT with Contents:Read>
```

On Windows, an existing Git Credential Manager login is reused automatically **when the
task runs in your logged-on session** (the `AtLogOn` trigger). It is not available before
logon or under a pure S4U/headless context — there, use an SSH deploy key or the store
helper.

### Troubleshooting

| Symptom (in the log) | Cause | Fix |
|----------------------|-------|-----|
| `could not read Username … terminal prompts disabled` | No durable credentials for this user | Set up a deploy key or `credential.helper store` (above) |
| `ERROR: docker compose не знайдено` | Scheduler's minimal `PATH` misses `docker` | The worker already extends `PATH`; if still failing, `which docker` and add its dir |
| Worker runs but never redeploys | Already up to date, or checking a different branch | Confirm `git rev-parse --abbrev-ref HEAD` is the branch you push to |
| Nothing in the log at all | cron not firing / task not registered | `crontab -l` (Linux) or `Get-ScheduledTask` (Windows); ensure the daemon/service is enabled |
| `Permission denied` running `*.sh` | Missing exec bit after checkout | `chmod +x *.sh`, or invoke via `bash <script>.sh` |

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
