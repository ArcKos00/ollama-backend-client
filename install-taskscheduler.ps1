<#
.SYNOPSIS
    Реєструє update-and-redeploy.ps1 на автозапуск після перезавантаження
    системи через Windows Task Scheduler. Watcher працює в циклі й сам
    стежить за оновленнями репозиторію.

.DESCRIPTION
    Створює завдання, яке запускається при старті системи (AtStartup) від
    імені поточного користувача з найвищими правами. Вивід пишеться у
    update-and-redeploy.log через Start-Transcript.

    Запускати цей скрипт треба у PowerShell з правами адміністратора.

.PARAMETER PollInterval
    Інтервал перевірки оновлень у секундах (за замовчуванням 60).

.PARAMETER Uninstall
    Видалити зареєстроване завдання.

.EXAMPLE
    .\install-taskscheduler.ps1
    Встановити автозапуск.

.EXAMPLE
    .\install-taskscheduler.ps1 -PollInterval 30

.EXAMPLE
    .\install-taskscheduler.ps1 -Uninstall
    Прибрати автозапуск.
#>
[CmdletBinding()]
param(
    [int]    $PollInterval = 60,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$TaskName = 'OllamaProcessor-AutoRedeploy'
$RepoDir  = $PSScriptRoot
$Watcher  = Join-Path $RepoDir 'update-and-redeploy.ps1'
$LogFile  = Join-Path $RepoDir 'update-and-redeploy.log'

# --- Перевірка прав адміністратора ----------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Запустіть цей скрипт у PowerShell з правами адміністратора."
    exit 1
}

# --- Видалення ------------------------------------------------------------
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

# --- Встановлення ---------------------------------------------------------
if (-not (Test-Path $Watcher)) {
    Write-Error "Не знайдено $Watcher"
    exit 1
}

# Команда: у робочому циклі watcher-а логуємо все у файл через транскрипт.
# InitialDeploy:$true — при старті системи одразу піднімаємо контейнери.
$innerCommand = @"
Start-Transcript -Path '$LogFile' -Append;
& '$Watcher' -PollInterval $PollInterval -InitialDeploy `$true;
Stop-Transcript
"@
# Прибираємо переноси рядків, щоб передати одним рядком у -Command
$innerCommand = ($innerCommand -replace "`r?`n", ' ').Trim()

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$innerCommand`"" `
    -WorkingDirectory $RepoDir

$trigger = New-ScheduledTaskTrigger -AtStartup

# Запуск від імені поточного користувача, з найвищими правами, без пароля (S4U)
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType S4U `
    -RunLevel Highest

# Не вимикати завдання при роботі від батареї; дозволити довге виконання
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'Стежить за git-репо OllamaProcessor і робить повний перебілд docker compose при новому коміті.' `
    -Force | Out-Null

Write-Host "Завдання '$TaskName' зареєстровано."
Write-Host "  Скрипт  : $Watcher"
Write-Host "  Лог     : $LogFile"
Write-Host "  Інтервал: $PollInterval с"
Write-Host ""
Write-Host "Запустити зараз вручну:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Переглянути завдання:    Get-ScheduledTask -TaskName '$TaskName'"
Write-Host "Прибрати автозапуск:     .\install-taskscheduler.ps1 -Uninstall"
Write-Host ""
Write-Host "УВАГА: Docker Desktop на Windows працює в сесії користувача. Якщо"
Write-Host "контейнери потрібні до входу в систему — використовуйте Docker Engine"
Write-Host "як службу, або змініть тригер на AtLogOn."
