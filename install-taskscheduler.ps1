<#
.SYNOPSIS
    СКРИПТ 1 — інсталятор (Windows).
    Реєструє в Task Scheduler завдання, яке періодично (кожні N хв) запускає
    update-and-redeploy.ps1 (СКРИПТ 2). Той щоразу перевіряє оновлення і за
    потреби робить редеплой. Завдання переживає перезавантаження системи.

.PARAMETER IntervalMinutes
    Інтервал запуску у хвилинах (за замовчуванням 5).

.PARAMETER Uninstall
    Видалити зареєстроване завдання.

.EXAMPLE
    .\install-taskscheduler.ps1
    Кожні 5 хвилин.

.EXAMPLE
    .\install-taskscheduler.ps1 -IntervalMinutes 10

.EXAMPLE
    .\install-taskscheduler.ps1 -Uninstall

.NOTES
    Запускати у PowerShell з правами адміністратора.
#>
[CmdletBinding()]
param(
    [int]    $IntervalMinutes = 5,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$TaskName = 'OllamaProcessor-AutoRedeploy'
$RepoDir  = $PSScriptRoot
$Worker   = Join-Path $RepoDir 'update-and-redeploy.ps1'
$LogFile  = Join-Path $RepoDir 'update-and-redeploy.log'

# --- Права адміністратора --------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Запустіть цей скрипт у PowerShell з правами адміністратора."
    exit 1
}

# --- Видалення -------------------------------------------------------------
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Завдання '$TaskName' видалено."
    }
    else {
        Write-Host "Завдання '$TaskName' не знайдено — нічого видаляти."
    }
    exit 0
}

# --- Встановлення ----------------------------------------------------------
if (-not (Test-Path $Worker)) {
    Write-Error "Не знайдено $Worker"
    exit 1
}

# Команда: запускаємо Скрипт 2, увесь вивід дописуємо в лог
$innerCommand = "& '$Worker' *>> '$LogFile'"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$innerCommand`"" `
    -WorkingDirectory $RepoDir

# Тригер: старт при вході в систему + повторення кожні N хвилин безстроково.
# (AtLogOn краще за AtStartup, бо Docker Desktop живе в сесії користувача.)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition

# Запуск від поточного користувача, найвищі права, без збереження пароля (S4U)
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType S4U `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Періодично перевіряє git-репо OllamaProcessor і робить повний перебілд docker compose при новому коміті.' `
    -Force | Out-Null

Write-Host "Завдання '$TaskName' зареєстровано."
Write-Host "  Скрипт 2 : $Worker"
Write-Host "  Розклад  : кожні $IntervalMinutes хв"
Write-Host "  Лог      : $LogFile"
Write-Host ""
Write-Host "Запустити зараз:   Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Прибрати:          .\install-taskscheduler.ps1 -Uninstall"
Write-Host ""
Write-Host "Перший запуск стека зробіть вручну:  docker compose up -d --build"
