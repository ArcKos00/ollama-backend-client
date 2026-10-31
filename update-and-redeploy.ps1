<#
.SYNOPSIS
    СКРИПТ (Windows) — самооновлюваний клієнт OllamaProcessor.

.DESCRIPTION
    Перевіряє, чи зʼявився новий коміт в origin/<гілка> для ЦЬОГО ж репо (того,
    з якого запущено скрипт). Якщо так — викачує його (git reset --hard) і
    перезбирає/перезапускає docker compose. Якщо ні — виходить.

    Один файл = і робоча одиниця (її викликає Task Scheduler), і встановлювач
    розкладу.

.EXAMPLE
    .\update-and-redeploy.ps1
    Одноразова перевірка + редеплой за потреби.

.EXAMPLE
    .\update-and-redeploy.ps1 -Install -IntervalMinutes 5
    Зареєструвати завдання Task Scheduler (кожні 5 хв) + первинна перевірка.
    Запускати у PowerShell з правами адміністратора.

.EXAMPLE
    .\update-and-redeploy.ps1 -Uninstall
    Прибрати зареєстроване завдання.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Install')]   [switch] $Install,
    [Parameter(ParameterSetName = 'Uninstall')] [switch] $Uninstall,
    [int] $IntervalMinutes = 5
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$Self     = $MyInvocation.MyCommand.Path
$LogFile  = Join-Path $PSScriptRoot 'update-and-redeploy.log'
$TaskName = 'OllamaProcessor-AutoRedeploy'

function Write-Log {
    param([string] $Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# docker compose v2 ("docker compose") або v1 ("docker-compose")
function Get-Compose {
    & docker compose version *> $null
    if ($LASTEXITCODE -eq 0) { return , @('docker', 'compose') }
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) { return , @('docker-compose') }
    throw "не знайдено ані 'docker compose', ані 'docker-compose'."
}

function Invoke-DC {
    param(
        [string[]] $Compose,
        [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Rest
    )
    $exe = $Compose[0]
    $prefix = @()
    if ($Compose.Length -gt 1) { $prefix = $Compose[1..($Compose.Length - 1)] }
    & $exe @prefix @Rest
    if ($LASTEXITCODE -ne 0) { throw "docker compose завершився з кодом $LASTEXITCODE" }
}

function Invoke-Run {
    # Захист від накладання запусків (перебілд може тривати довше за інтервал).
    $mutex = New-Object System.Threading.Mutex($false, 'Global\OllamaProcessorAutoRedeploy')
    if (-not $mutex.WaitOne(0)) {
        Write-Log "Інший запуск ще працює — пропускаю цю ітерацію."
        return
    }
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $dc = Get-Compose

        $branch = (git rev-parse --abbrev-ref HEAD).Trim()

        git fetch origin $branch
        if ($LASTEXITCODE -ne 0) {
            throw "git fetch не вдався. Перевір доступ до origin / креденшли."
        }

        $local  = (git rev-parse HEAD).Trim()
        $remote = (git rev-parse "origin/$branch").Trim()

        if ($local -eq $remote) {
            Write-Log "Оновлень немає (гілка '$branch', HEAD=$($local.Substring(0,7)))."
            return
        }

        Write-Log "Новий коміт у '$branch': $($local.Substring(0,7)) -> $($remote.Substring(0,7)). Оновлюю..."
        # Жорсткий reset: деплой = точний стан origin/<гілка>.
        git reset --hard "origin/$branch"
        if ($LASTEXITCODE -ne 0) { throw "git reset завершився з кодом $LASTEXITCODE" }

        Write-Log "Перезбірка та перезапуск docker compose..."
        Invoke-DC $dc up -d --build --remove-orphans
        Write-Log "Готово. Розгорнуто $($remote.Substring(0,7))."
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Assert-Admin {
    $principal = [Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Запустіть цей скрипт у PowerShell з правами адміністратора."
    }
}

function Invoke-Install {
    Assert-Admin

    # Команда для планувальника: запуск цього ж файлу, увесь вивід — у лог.
    $inner = "& '$Self' *>> '$LogFile'"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$inner`"" `
        -WorkingDirectory $PSScriptRoot

    # AtLogOn + повторення кожні N хв (Docker Desktop живе в сесії користувача).
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
            -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition

    $principal = New-ScheduledTaskPrincipal `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType S4U -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Самооновлення OllamaProcessor: перевірка git і docker compose rebuild при новому коміті.' `
        -Force | Out-Null

    Write-Log "Завдання '$TaskName' зареєстровано: кожні $IntervalMinutes хв. Лог: $LogFile"
    Write-Log "Прибрати: .\update-and-redeploy.ps1 -Uninstall"
    Write-Log "Роблю первинну перевірку зараз..."
    Invoke-Run
}

function Invoke-Uninstall {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "Завдання '$TaskName' видалено."
    }
    else {
        Write-Log "Завдання '$TaskName' не знайдено — нічого видаляти."
    }
}

if     ($Install)   { Invoke-Install }
elseif ($Uninstall) { Invoke-Uninstall }
else                { Invoke-Run }
