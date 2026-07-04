<#
.SYNOPSIS
    СКРИПТ 2 — робоча одиниця (Windows).
    Одноразова перевірка оновлень поточного git-репо: якщо в origin/<гілка>
    зʼявився новий коміт — викачує його і робить повний перебілд docker
    compose (--no-cache). Якщо оновлень немає — виходить.

.DESCRIPTION
    Призначений для періодичного запуску з Task Scheduler
    (див. install-taskscheduler.ps1), але можна запускати й вручну:
        .\update-and-redeploy.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# --- Захист від паралельних запусків (mutex) -------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\OllamaProcessorAutoRedeploy')
if (-not $mutex.WaitOne(0)) {
    Write-Log "Інший запуск ще працює — пропускаю цю ітерацію."
    exit 0
}

try {
    # --- Команда docker compose (v2 "docker compose" чи v1) ---------------
    & docker compose version *> $null
    if ($LASTEXITCODE -eq 0) {
        $dc = @('docker', 'compose')
    }
    elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        $dc = @('docker-compose')
    }
    else {
        Write-Log "ERROR: не знайдено ані 'docker compose', ані 'docker-compose'."
        exit 1
    }

    function Invoke-DC {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
        $exe, $prefix = $dc[0], $dc[1..($dc.Length - 1)]
        & $exe @prefix @Args
        if ($LASTEXITCODE -ne 0) { throw "docker compose завершився з кодом $LASTEXITCODE" }
    }

    $branch = (git rev-parse --abbrev-ref HEAD).Trim()

    # --- Перевірка оновлень -----------------------------------------------
    git fetch --quiet origin $branch
    $local  = (git rev-parse HEAD).Trim()
    $remote = (git rev-parse "origin/$branch").Trim()

    if ($local -eq $remote) {
        Write-Log "Оновлень немає (гілка '$branch', HEAD=$($local.Substring(0,7)))."
        exit 0
    }

    # --- Оновлення + редеплой ---------------------------------------------
    Write-Log "Новий коміт у '$branch': $($local.Substring(0,7)) -> $($remote.Substring(0,7)). Оновлюю..."
    git reset --hard "origin/$branch"
    if ($LASTEXITCODE -ne 0) { throw "git reset завершився з кодом $LASTEXITCODE" }

    Write-Log "Повний перебілд і перезапуск docker compose..."
    Invoke-DC down --remove-orphans
    Invoke-DC build --no-cache
    Invoke-DC up -d --force-recreate
    Write-Log "Готово. Розгорнуто $($remote.Substring(0,7))."
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
