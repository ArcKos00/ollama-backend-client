<#
.SYNOPSIS
    Стежить за поточним git-репозиторієм і при появі нового коміта у
    відстежуваній гілці викачує зміни та робить повний перебілд docker compose.

.DESCRIPTION
    1. Викачує зміни (git fetch + hard reset до origin/<гілка>);
    2. Перезапускає docker compose з повним перебілдом (--no-cache).

.EXAMPLE
    .\update-and-redeploy.ps1
    Цикл з інтервалом 60 секунд.

.EXAMPLE
    .\update-and-redeploy.ps1 -PollInterval 30 -InitialDeploy:$false

.EXAMPLE
    .\update-and-redeploy.ps1 -Once
    Разова перевірка без циклу.
#>
[CmdletBinding()]
param(
    [int]    $PollInterval  = 60,      # інтервал перевірки, секунди
    [switch] $Once,                    # перевірити один раз і вийти
    [bool]   $InitialDeploy = $true    # зробити деплой одразу при старті
)

$ErrorActionPreference = 'Stop'

# Переходимо в директорію скрипта (== корінь репозиторію)
Set-Location -Path $PSScriptRoot

# --- Визначаємо команду docker compose (v2 "docker compose" чи v1) --------
$script:DockerCompose = $null
& docker compose version *> $null
if ($LASTEXITCODE -eq 0) {
    $script:DockerCompose = @('docker', 'compose')
}
elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
    $script:DockerCompose = @('docker-compose')
}
else {
    Write-Error "Не знайдено ані 'docker compose', ані 'docker-compose'."
    exit 1
}

$Branch = (git rev-parse --abbrev-ref HEAD).Trim()

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Invoke-DockerCompose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $exe, $prefix = $script:DockerCompose[0], $script:DockerCompose[1..($script:DockerCompose.Length - 1)]
    & $exe @prefix @Args
    if ($LASTEXITCODE -ne 0) { throw "docker compose завершився з кодом $LASTEXITCODE" }
}

function Invoke-Redeploy {
    Write-Log "Повний перебілд і перезапуск docker compose..."
    Invoke-DockerCompose down --remove-orphans
    Invoke-DockerCompose build --no-cache
    Invoke-DockerCompose up -d --force-recreate
    Write-Log "Готово. Контейнери підняті."
}

function Update-Repo {
    Write-Log "Виявлено новий коміт — викачую зміни..."
    # Жорсткий reset гарантує, що деплой = точний стан origin/<гілка>
    git reset --hard "origin/$Branch"
    if ($LASTEXITCODE -ne 0) { throw "git reset завершився з кодом $LASTEXITCODE" }
    Write-Log "Репозиторій оновлено до $(git rev-parse --short HEAD)."
}

function Test-ForUpdates {
    git fetch --quiet origin $Branch
    $localRev  = (git rev-parse HEAD).Trim()
    $remoteRev = (git rev-parse "origin/$Branch").Trim()

    if ($localRev -ne $remoteRev) {
        Update-Repo
        Invoke-Redeploy
    }
    else {
        Write-Log "Оновлень немає (HEAD = $($localRev.Substring(0,7)))."
    }
}

# --- Старт -----------------------------------------------------------------
Write-Log "Стеження за гілкою '$Branch'. Docker: '$($script:DockerCompose -join ' ')'. Інтервал: $PollInterval с."

if ($InitialDeploy) {
    Write-Log "Початковий деплой при старті..."
    Invoke-Redeploy
}

if ($Once) {
    Test-ForUpdates
    exit 0
}

# Основний цикл
while ($true) {
    try {
        Test-ForUpdates
    }
    catch {
        Write-Log "УВАГА: ітерація завершилась з помилкою: $($_.Exception.Message). Продовжую."
    }
    Start-Sleep -Seconds $PollInterval
}
