# ---------------------------------------------------------
# Per-User Software Installer (No Elevation)
# Order:
# 1) Zoom EXE
# 2) IPEVO Visualizer MSI (per-user attempt)
# 3) DisplayNote Montage EXE
# ---------------------------------------------------------

$ErrorActionPreference = "Stop"

$BaseDir = Join-Path $env:TEMP "AppInstallers"
$LogDir  = Join-Path $BaseDir "Logs"
New-Item -ItemType Directory -Force -Path $BaseDir, $LogDir | Out-Null

function Write-Log {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "[$stamp] $Message"
  Write-Host $line
  Add-Content -Path (Join-Path $LogDir "install.log") -Value $line
}

function Download-File {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutFile
  )

  Write-Log "Downloading: $Url"
  try {
    # Use curl.exe for better handling of redirects and long query URLs
    & "$env:SystemRoot\System32\curl.exe" -L --fail --retry 3 --retry-delay 2 -o "$OutFile" "$Url"
  } catch {
    Write-Log "curl.exe failed. Falling back to Invoke-WebRequest..."
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  }

  if (!(Test-Path $OutFile) -or ((Get-Item $OutFile).Length -lt 10KB)) {
    throw "Download failed or file too small: $OutFile"
  }

  Write-Log "Saved to: $OutFile ($([Math]::Round((Get-Item $OutFile).Length/1MB,2)) MB)"
}

function Run-Exe {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Args,
    [string]$Name = "EXE"
  )

  $log = Join-Path $LogDir ($Name.Replace(" ","_") + ".log")
  Write-Log "Running $Name: $Path $Args"
  Write-Log "Log: $log"

  # Many EXEs don’t support /log; we capture stdout/stderr anyway
  $p = Start-Process -FilePath $Path -ArgumentList $Args -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $log -RedirectStandardError $log

  Write-Log "$Name exit code: $($p.ExitCode)"
  return $p.ExitCode
}

function Run-MsiPerUser {
  param(
    [Parameter(Mandatory)][string]$MsiPath,
    [Parameter(Mandatory)][string]$Name
  )

  $log = Join-Path $LogDir ($Name.Replace(" ","_") + ".msi.log")
  # Per-user MSI attempt:
  # - ALLUSERS=2 + MSIINSTALLPERUSER=1 requests per-user context where supported
  $args = "/i `"$MsiPath`" /qn /norestart ALLUSERS=2 MSIINSTALLPERUSER=1 /l*v `"$log`""

  Write-Log "Running MSI (per-user attempt): $Name"
  Write-Log "Log: $log"

  $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru -NoNewWindow
  Write-Log "$Name MSI exit code: $($p.ExitCode)"
  return $p.ExitCode
}

# -----------------------------
# URLs (in order)
# -----------------------------
$ZoomUrl = "https://cdn.zoom.us/prod/6.6.11.23272/x64/ZoomInstallerFull.exe"
$IpevoUrl = "https://ipevo-software.s3.us-east-1.amazonaws.com/Visualizer/Windows/VisualizerDesktop_4.2.17.0.msi"
$DisplayNoteUrl = "https://releases-static.displaynote.com/0e12d653%2Fd0a1%2F4987%2Fa369%2Fdfb8f5b7ea86%2FDisplaynoteMontageClient-2.48.1.49949.exe?response-content-disposition=attachment%3B%20filename%3Ddisplaynote-windows-2.48.1.49949-released.exe%3B%20size%3D171848312"

# File paths
$ZoomExe      = Join-Path $BaseDir "ZoomInstallerFull.exe"
$IpevoMsi     = Join-Path $BaseDir "VisualizerDesktop_4.2.17.0.msi"
$DisplayNoteExe = Join-Path $BaseDir "DisplaynoteMontageClient.exe"

Write-Log "=== Starting installs as user: $env:USERNAME (elevated: $([bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) ==="

# -----------------------------
# 1) Zoom (prefer per-user by NOT elevating)
# Common silent args for Zoom:
# /quiet /norestart is commonly accepted.
# -----------------------------
try {
  Download-File -Url $ZoomUrl -OutFile $ZoomExe
  $code = Run-Exe -Path $ZoomExe -Args "/quiet /norestart" -Name "Zoom"
  if ($code -ne 0) {
    Write-Log "Zoom returned non-zero exit code ($code). It may require different switches or admin on this machine."
  }
} catch {
  Write-Log "Zoom install failed: $($_.Exception.Message)"
}

# -----------------------------
# 2) IPEVO Visualizer (MSI per-user attempt)
# -----------------------------
try {
  Download-File -Url $IpevoUrl -OutFile $IpevoMsi
  $code = Run-MsiPerUser -MsiPath $IpevoMsi -Name "IPEVO_Visualizer"
  if ($code -ne 0) {
    Write-Log "IPEVO MSI returned non-zero exit code ($code). This MSI may not support per-user install and could require admin."
  }
} catch {
  Write-Log "IPEVO install failed: $($_.Exception.Message)"
}

# -----------------------------
# 3) DisplayNote Montage (try common silent switches)
# Many installers use one of these:
# - /S
# - /silent
# - /verysilent /suppressmsgboxes /norestart /sp-
# We'll try a couple, stopping if one succeeds.
# -----------------------------
try {
  Download-File -Url $DisplayNoteUrl -OutFile $DisplayNoteExe

  $attempts = @(
    @{ Name="DisplayNote_try1"; Args="/verysilent /suppressmsgboxes /norestart /sp-" },
    @{ Name="DisplayNote_try2"; Args="/S" },
    @{ Name="DisplayNote_try3"; Args="/silent /norestart" },
    @{ Name="DisplayNote_try4"; Args="/quiet" }
  )

  $success = $false
  foreach ($a in $attempts) {
    $code = Run-Exe -Path $DisplayNoteExe -Args $a.Args -Name $a.Name
    if ($code -eq 0) { $success = $true; break }
  }

  if (-not $success) {
    Write-Log "DisplayNote did not return exit code 0 with common silent switches. It may require different parameters or admin."
  }
} catch {
  Write-Log "DisplayNote install failed: $($_.Exception.Message)"
}

Write-Log "=== Finished. Logs are in: $LogDir ==="
