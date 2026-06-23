# syntax=docker/dockerfile:1

# ---- Build stage ----
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first (cached unless the project file changes).
COPY OllamaProcessor.csproj ./
RUN dotnet restore OllamaProcessor.csproj

# Build & publish.
COPY . .
RUN dotnet publish OllamaProcessor.csproj -c Release -o /app/publish \
    /p:UseAppHost=false

# ---- Runtime stage ----
FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final
WORKDIR /app

# Run as the non-root user shipped in the .NET images.
USER $APP_UID

# Default to Production; override config via environment variables, e.g.
#   -e RabbitMq__HostName=... -e RabbitMq__Password=... -e Ollama__BaseUrl=...
ENV DOTNET_ENVIRONMENT=Production

COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "OllamaProcessor.dll"]
