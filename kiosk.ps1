# Bathroom Kiosk Full Installer (All-in-One, Notepad-proof)
# ---------------------------------------------------------
# - Self-elevates (UAC)
# - Disables sleep/display timeout + hibernate
# - Downloads bathroom.exe
# - Creates 5PM auto logout task (SYSTEM)
# - Creates AC disconnect alarm task (runs in kiosk user session so audio works)
# - Launches kiosk

$ErrorActionPreference = "Stop"

# >>> CHANGE THIS if needed <<<
# Local user example: ".\BathroomKiosk"
# Domain user example: "SCHOOL\BathroomKiosk"
$KioskUser = "ILT\wemssub1"   # <<< The domain user the alarm task will run as at logon

$Url = "https://github.com/antho-444/powershell-install/releases/download/1.1/bathroom.exe"
$InstallDir = Join-Path $env:ProgramData "BathroomKiosk"
$ExePath = Join-Path $InstallDir "bathroom.exe"

$LogoutTaskName   = "BathroomKiosk_AutoLogout_5PM"
$AlarmTaskName    = "BathroomKiosk_ACDisconnect_AlarmMonitor"
$AlarmScriptPath  = Join-Path $InstallDir "ac-alarm-monitor.ps1"

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Run-Native {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$Arguments
    )
    Write-Host "RUN: $FilePath $Arguments"
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
        throw "Command failed: $FilePath $Arguments (ExitCode $($p.ExitCode))"
    }
}

# ---------------------------
# UAC Elevation
# ---------------------------
if (-not (Test-IsAdmin)) {
    Write-Host ""
    Write-Host "ERROR: This script must be run as an Administrator." -ForegroundColor Red
    Write-Host ""
    Write-Host "Please open PowerShell as an admin account (not as the kiosk user) and run:" -ForegroundColor Yellow
    Write-Host "   irm <your-url> | iex" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "The kiosk user (e.g. ILT\wemssub1) does NOT need to run this." -ForegroundColor Yellow
    Write-Host "Just make sure the KioskUser variable at the top of the script is set to that account." -ForegroundColor Yellow
    Write-Host ""
    pause
    exit 1
}

Write-Host "Running as Administrator..." -ForegroundColor Green

# ---------------------------
# Disable Sleep + Display Timeout
# ---------------------------
Write-Host "Disabling sleep, display timeout, and hibernation..."
Run-Native "powercfg.exe" "-change -standby-timeout-ac 0"
Run-Native "powercfg.exe" "-change -standby-timeout-dc 0"
Run-Native "powercfg.exe" "-change -monitor-timeout-ac 0"
Run-Native "powercfg.exe" "-change -monitor-timeout-dc 0"
try { Start-Process "powercfg.exe" -ArgumentList "-hibernate","off" -Wait -WindowStyle Hidden | Out-Null } catch {}

# ---------------------------
# Create Install Directory
# ---------------------------
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# ---------------------------
# Download Kiosk EXE
# ---------------------------
Write-Host "Downloading kiosk app..."
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Invoke-WebRequest -Uri $Url -OutFile $ExePath -UseBasicParsing
Unblock-File -Path $ExePath -ErrorAction SilentlyContinue

# ---------------------------
# Create 5PM Auto Logout Task (SYSTEM)
# ---------------------------
Write-Host "Creating 5PM auto logout task..."
try { Start-Process "schtasks.exe" -ArgumentList "/Delete","/TN",$LogoutTaskName,"/F" -Wait -WindowStyle Hidden | Out-Null } catch {}
Run-Native "schtasks.exe" "/Create /F /TN `"$LogoutTaskName`" /SC DAILY /ST 17:00 /RU SYSTEM /RL HIGHEST /TR `"shutdown.exe /l /f`""
Write-Host "Auto logout scheduled for 5:00 PM daily." -ForegroundColor Cyan

# ---------------------------
# Write AC Alarm Monitor Script
# ---------------------------
Write-Host "Writing AC alarm monitor script..."
$AlarmMonitor = @'
$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Windows.Forms

function OnAC {
    try { return ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq "Online") }
    catch { return $true }
}

while ($true) {
    if (-not (OnAC)) {
        while (-not (OnAC)) {
            try {
                [console]::Beep(1400, 350)
                Start-Sleep -Milliseconds 150
                [console]::Beep(900, 250)
                Start-Sleep -Milliseconds 350
            } catch {
                Write-Host "`a"
                Start-Sleep -Seconds 1
            }
        }
    }
    Start-Sleep -Seconds 2
}
'@
Set-Content -Path $AlarmScriptPath -Value $AlarmMonitor -Encoding UTF8

# ---------------------------
# Create Alarm Task using Register-ScheduledTask (more reliable for domain users)
# ---------------------------
Write-Host "Creating AC alarm scheduled task for user: $KioskUser"

# Delete old task if it exists
Unregister-ScheduledTask -TaskName $AlarmTaskName -Confirm:$false -ErrorAction SilentlyContinue

$AlarmAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AlarmScriptPath`""

$AlarmTrigger = New-ScheduledTaskTrigger -AtLogOn -User $KioskUser

$AlarmSettings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

$AlarmPrincipal = New-ScheduledTaskPrincipal `
    -UserId $KioskUser `
    -LogonType Interactive `
    -RunLevel Limited

try {
    Register-ScheduledTask `
        -TaskName $AlarmTaskName `
        -Action $AlarmAction `
        -Trigger $AlarmTrigger `
        -Settings $AlarmSettings `
        -Principal $AlarmPrincipal `
        -Force `
        -ErrorAction Stop
    Write-Host "AC disconnect alarm installed — will run at logon for: $KioskUser" -ForegroundColor Cyan
} catch {
    Write-Host "WARNING: Could not register task for $KioskUser — $_" -ForegroundColor Yellow
    Write-Host "This usually means the user has never logged into this machine yet." -ForegroundColor Yellow
    Write-Host "Re-run this installer after $KioskUser has logged in at least once." -ForegroundColor Yellow
}

# Start it immediately in the current session (so you don't need to log off/on to test)
Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AlarmScriptPath`""

# ---------------------------
# Launch Kiosk
# ---------------------------
Write-Host "Launching kiosk..."
Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir

Write-Host ""
Write-Host "Bathroom kiosk setup complete." -ForegroundColor Green
Write-Host "If you want the alarm to run for a specific kiosk account, run this installer while logged into that kiosk account." -ForegroundColor Yellow
