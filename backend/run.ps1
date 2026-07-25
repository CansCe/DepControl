# Loads backend/.env into the process environment, then starts Dart Frog.
#
# Usage:
#   .\run.ps1                      dev server with hot reload (ports 8080/8181)
#   .\run.ps1 -Port 8090           use a different HTTP port
#   .\run.ps1 -Force               stop whatever holds the ports, then start
#   .\run.ps1 -Build               production build into build/
param(
  [switch]$Build,
  [int]$Port = 8080,
  [int]$VmServicePort = 8181,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$envFile = Join-Path $PSScriptRoot '.env'

# --- Load .env ------------------------------------------------------------
if (Test-Path $envFile) {
  Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
      $idx = $line.IndexOf('=')
      $name = $line.Substring(0, $idx).Trim()
      $value = $line.Substring($idx + 1).Trim()
      # Strip surrounding quotes so KEY="value" behaves like KEY=value.
      if ($value.Length -ge 2 -and
          (($value.StartsWith('"') -and $value.EndsWith('"')) -or
           ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      Set-Item -Path "Env:$name" -Value $value
    }
  }
  Write-Host "[run] Loaded environment from .env" -ForegroundColor Green

  if ($env:DATABASE_URL -and $env:DATABASE_URL -match '[\[\]]') {
    Write-Host "[run] WARNING: DATABASE_URL still contains a placeholder (e.g. [YOUR-DB-PASSWORD])." -ForegroundColor Yellow
    Write-Host "[run]          Set the real password from Supabase -> Project Settings -> Database." -ForegroundColor Yellow
    Write-Host "[run]          The server will fall back to the in-memory repository." -ForegroundColor Yellow
  }
} else {
  Write-Host "[run] No .env found (copy .env.example -> .env). Using existing environment." -ForegroundColor Yellow
}

# --- Port pre-flight ------------------------------------------------------
# A dev server left running from a previous session keeps 8080/8181 bound, and
# dart_frog's own failure ("Failed to create server socket") doesn't say which
# process is at fault. Check first and give an actionable message.
function Get-PortOwner([int]$p) {
  Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
}

if (-not $Build) {
  $blocked = $false
  foreach ($p in @($Port, $VmServicePort)) {
    $conn = Get-PortOwner $p
    if (-not $conn) { continue }

    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    $desc = "port $p is in use by PID $($conn.OwningProcess) ($($proc.ProcessName))"

    if ($Force) {
      Write-Host "[run] $desc - stopping it (-Force)." -ForegroundColor Yellow
      Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 750
    } else {
      Write-Host "[run] ERROR: $desc." -ForegroundColor Red
      $blocked = $true
    }
  }

  if ($blocked) {
    Write-Host ""
    Write-Host "A previous dev server is probably still running. Either:" -ForegroundColor Cyan
    Write-Host "  .\run.ps1 -Force                 stop it and start fresh" -ForegroundColor Cyan
    Write-Host "  .\run.ps1 -Port 8090 -VmServicePort 8191   run alongside it" -ForegroundColor Cyan
    exit 1
  }
}

# --- Launch ---------------------------------------------------------------
Push-Location $PSScriptRoot
try {
  if ($Build) {
    dart_frog build
  } else {
    dart_frog dev --port $Port --dart-vm-service-port $VmServicePort
  }
} finally {
  Pop-Location
}
