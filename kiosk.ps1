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
$KioskUser = "$env:USERDOMAIN\$env:USERNAME"   # default: current user; replace with explicit kiosk user if different

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
    # When run via irm|iex, $PSCommandPath is empty — re-download to temp and relaunch elevated
    if (-not $PSCommandPath) {
        $TempScript = Join-Path $env:TEMP "kiosk-installer.ps1"
        $ScriptUrl  = "https://raw.githubusercontent.com/antho-444/powershell-install/refs/heads/main/kiosk.ps1"
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $TempScript -UseBasicParsing
        $elevateArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$TempScript`"")
    } else {
        $elevateArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    }
    Start-Process -FilePath "powershell.exe" -ArgumentList $elevateArgs -Verb RunAs
    exit
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
# Create Alarm Task via XML (targets specific domain kiosk user, no password needed)
# ---------------------------
Write-Host "Creating AC alarm scheduled task for user: $KioskUser"

# Delete old task if it exists
try { Start-Process "schtasks.exe" -ArgumentList "/Delete","/TN",$AlarmTaskName,"/F" -Wait -WindowStyle Hidden | Out-Null } catch {}

# Build the task XML targeting the specific kiosk user
# UserId in the trigger ensures it ONLY fires when THIS user logs on, not any user
$TaskXmlPath = Join-Path $InstallDir "ac-alarm-task.xml"
$AlarmTR = "powershell.exe"
$AlarmArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$AlarmScriptPath`""

$TaskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Beeps when AC power is disconnected. Runs in kiosk user session for audio.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$KioskUser</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$KioskUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$AlarmTR</Command>
      <Arguments>$AlarmArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# Write XML as UTF-16 (required by schtasks /XML)
$TaskXml | Out-File -FilePath $TaskXmlPath -Encoding Unicode

# Register the task using the XML — no password required for interactive logon tasks
Run-Native "schtasks.exe" "/Create /F /TN `"$AlarmTaskName`" /XML `"$TaskXmlPath`""

Write-Host "AC disconnect alarm installed — will run at logon for: $KioskUser" -ForegroundColor Cyan

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