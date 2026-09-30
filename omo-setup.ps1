<#
.SYNOPSIS
  Install OmO if missing, then configure a custom provider (baseUrl + apiKey + models).

.DESCRIPTION
  Windows entry point. Mirrors omo-setup.sh and shares omo-config.mjs for the
  actual config write. On Linux/macOS use omo-setup.sh instead.

.EXAMPLE
  .\omo-setup.ps1 -BaseUrl https://api.example.com/v1 -ApiKey sk-xxx -Models gpt-4o,gpt-4o-mini

.EXAMPLE
  $env:OMO_BASE_URL="https://api.example.com/v1"; $env:OMO_API_KEY="sk-xxx"; $env:OMO_MODELS="gpt-4o"
  .\omo-setup.ps1
#>
[CmdletBinding()]
param(
  [string]$BaseUrl  = $env:OMO_BASE_URL,
  [string]$ApiKey   = $env:OMO_API_KEY,
  [string]$Models   = $env:OMO_MODELS,
  [string]$Provider = $env:OMO_PROVIDER,
  [ValidateSet('openai-completions','openai-responses','anthropic-messages')]
  [string]$ApiType  = $(if ($env:OMO_API_TYPE) { $env:OMO_API_TYPE } else { 'openai-completions' }),
  [string]$DefaultModel,
  [switch]$NoDefault,
  [switch]$DryRun,
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "!! $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "xx $m" -ForegroundColor Red; exit 1 }

function Find-Omo {
  $cmd = Get-Command omo -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($d in @("$env:USERPROFILE\.bun\bin", "$env:LOCALAPPDATA\omo\bin", "$env:USERPROFILE\.omo\bin")) {
    $p = Join-Path $d 'omo.exe'
    if (Test-Path $p) { return $p }
    $p2 = Join-Path $d 'omo.cmd'
    if (Test-Path $p2) { return $p2 }
  }
  return $null
}

function Install-Omo {
  Info 'omo not found - installing OmO Native'
  try {
    Invoke-RestMethod -Uri 'https://get.omo.dev/install.ps1' | Invoke-Expression
  } catch {
    if (Get-Command bun -ErrorAction SilentlyContinue) {
      bun add -g omo-ai
    } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
      npm i -g omo-ai
    } else {
      Die "official installer failed and no bun/npm fallback: $($_.Exception.Message)"
    }
  }
}

if (-not $SkipInstall) {
  $omoBin = Find-Omo
  if ($omoBin) {
    $ver = & $omoBin --version 2>$null
    Info "omo already installed: $ver"
    Info 'skipping installation'
  } else {
    Install-Omo
    $omoBin = Find-Omo
    if (-not $omoBin) { Die 'omo installed but not found on PATH; open a new terminal and re-run' }
    Info "installed: $(& $omoBin --version 2>$null)"
  }
} else {
  Info 'SkipInstall set, not checking installation'
}

$configArgs = @()
if ($BaseUrl)      { $configArgs += @('--base-url', $BaseUrl) }
if ($ApiKey)       { $configArgs += @('--api-key', $ApiKey) }
if ($Models)       { $configArgs += @('--models', $Models) }
if ($Provider)     { $configArgs += @('--provider', $Provider) }
if ($ApiType)      { $configArgs += @('--api-type', $ApiType) }
if ($DefaultModel) { $configArgs += @('--default-model', $DefaultModel) }
if ($NoDefault)    { $configArgs += '--no-default' }
if ($DryRun)       { $configArgs += '--dry-run' }

$configScript = Join-Path $ScriptDir 'omo-config.mjs'
if (-not (Test-Path $configScript)) { Die "missing $configScript" }

Info 'configuring provider'
if (Get-Command node -ErrorAction SilentlyContinue) {
  & node $configScript @configArgs
} elseif (Get-Command bun -ErrorAction SilentlyContinue) {
  & bun $configScript @configArgs
} else {
  Die 'need node or bun to write omo config'
}
if ($LASTEXITCODE -ne 0) { Die "config step failed (exit $LASTEXITCODE)" }
