# syntax=docker/dockerfile:1

# ---- Build stage ----
FROM 10.20.50.25:8081/dotnet/sdk:10.0 AS build
WORKDIR /src

# Quieter, faster, fewer network round-trips during restore.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    NUGET_XMLDOC_MODE=skip

# Restore first (cached unless the project file changes). A BuildKit cache mount keeps
# the NuGet package cache across builds, and NuGetAudit=false drops the vulnerability
# endpoint round-trip that can stall restore on locked-down networks.
COPY OllamaProcessor.csproj ./
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet restore OllamaProcessor.csproj -p:NuGetAudit=false

# Build & publish.
COPY . .
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish OllamaProcessor.csproj -c Release -o /app/publish \
    --no-restore -p:UseAppHost=false

# ---- Runtime stage ----
FROM 10.20.50.25:8081/dotnet/aspnet:10.0 AS final
WORKDIR /app

# Run as the non-root user shipped in the .NET images.
USER $APP_UID

# Default to Production; override config via environment variables, e.g.
#   -e RabbitMq__HostName=... -e RabbitMq__Password=... -e Ollama__BaseUrl=...
ENV DOTNET_ENVIRONMENT=Production

COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "OllamaProcessor.dll"]
