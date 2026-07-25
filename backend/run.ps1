# Loads backend/.env into the process environment, then starts Dart Frog.
# Usage:  .\run.ps1            (dev server with hot reload)
#         .\run.ps1 -Build     (production build into build/)
param([switch]$Build)

$ErrorActionPreference = 'Stop'
$envFile = Join-Path $PSScriptRoot '.env'

if (Test-Path $envFile) {
  Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
      $idx = $line.IndexOf('=')
      $name = $line.Substring(0, $idx).Trim()
      $value = $line.Substring($idx + 1).Trim()
      Set-Item -Path "Env:$name" -Value $value
    }
  }
  Write-Host "[run] Loaded environment from .env" -ForegroundColor Green
} else {
  Write-Host "[run] No .env found (copy .env.example -> .env). Using existing environment." -ForegroundColor Yellow
}

Push-Location $PSScriptRoot
try {
  if ($Build) { dart_frog build } else { dart_frog dev }
} finally {
  Pop-Location
}
