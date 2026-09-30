<#
.SYNOPSIS
  Install OmO if missing, then configure a provider, step by step.

.DESCRIPTION
  Windows entry point. Mirrors omo-setup.sh and shares omo-config.mjs for the
  actual config write. Run with no arguments for an interactive wizard, or pass
  parameters for scripted use. On Linux/macOS use omo-setup.sh instead.

.EXAMPLE
  .\omo-setup.ps1

.EXAMPLE
  .\omo-setup.ps1 -BaseUrl https://api.example.com/v1 -ApiKey sk-xxx -Models gpt-4o,gpt-4o-mini
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
  [switch]$Interactive,
  [switch]$NoDefault,
  [switch]$DryRun,
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$RawBase = 'https://raw.githubusercontent.com/zxfccmm4/omo-setup/main'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "!! $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "xx $m" -ForegroundColor Red; exit 1 }

function Mask($s) {
  if (-not $s) { return '' }
  if ($s.Length -le 8) { return '********' }
  return $s.Substring(0,4) + '...' + $s.Substring($s.Length-4)
}

function Ask($msg, $default) {
  if ($default) { Write-Host "$msg [$default]: " -NoNewline -ForegroundColor Gray }
  else { Write-Host "${msg}: " -NoNewline -ForegroundColor Gray }
  $v = [Console]::ReadLine()
  if ([string]::IsNullOrEmpty($v)) { return $default }
  return $v
}

function Ask-Secret($msg) {
  Write-Host "${msg}: " -NoNewline -ForegroundColor Gray
  $secure = Read-Host -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Ask-Yes($msg, $default) {
  if (-not $default) { $default = 'n' }
  Write-Host "$msg [$default]: " -NoNewline -ForegroundColor Gray
  $v = [Console]::ReadLine()
  if ([string]::IsNullOrEmpty($v)) { $v = $default }
  return ($v -match '^(y|yes)$')
}

function Find-Omo {
  $cmd = Get-Command omo -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($d in @("$env:USERPROFILE\.bun\bin", "$env:LOCALAPPDATA\omo\bin", "$env:USERPROFILE\.omo\bin")) {
    foreach ($name in @('omo.exe','omo.cmd','omo')) {
      $p = Join-Path $d $name
      if (Test-Path $p) { return $p }
    }
  }
  return $null
}

function Install-Omo {
  Info 'installing OmO Native'
  try {
    Invoke-RestMethod -Uri 'https://get.omo.dev/install.ps1' | Invoke-Expression
  } catch {
    if (Get-Command bun -ErrorAction SilentlyContinue) { bun add -g omo-ai }
    elseif (Get-Command npm -ErrorAction SilentlyContinue) { npm i -g omo-ai }
    else { Die "official installer failed and no bun/npm fallback: $($_.Exception.Message)" }
  }
}

function Invoke-Wizard {
  Write-Host ''
  Info 'step-by-step setup (press Enter to accept the [default])'
  Write-Host ''

  if (-not $BaseUrl) { $BaseUrl = Ask '1) Endpoint base URL (e.g. https://api.example.com/v1)' $null }
  if (-not $BaseUrl) { Die 'base URL is required' }

  if (-not $ApiKey) {
    $k = Ask-Secret '2) API key'
    if ($k) { $ApiKey = $k }
  }
  if (-not $ApiKey) { Die 'API key is required' }

  if (-not $Models) { $Models = Ask '3) Model ids, comma-separated (e.g. gpt-4o,gpt-4o-mini)' $null }
  if (-not $Models) { Die 'at least one model is required' }

  $Provider = Ask '4) Provider name (blank = auto from host)' $Provider

  Write-Host '5) API protocol:  1) openai-completions (default)  2) openai-responses  3) anthropic-messages'
  $choice = Ask '   choose [1-3]' '1'
  switch ($choice) {
    '2' { $ApiType = 'openai-responses' }
    '3' { $ApiType = 'anthropic-messages' }
    '1' { $ApiType = 'openai-completions' }
    default { Warn "unknown choice '$choice', using openai-completions"; $ApiType = 'openai-completions' }
  }

  $DefaultModel = Ask '6) Default model (blank = provider/<first model>)' $DefaultModel

  Write-Host ''
  Info 'about to write:'
  Write-Host "   Base URL : $BaseUrl"
  Write-Host "   API key  : $(Mask $ApiKey)"
  Write-Host "   Models   : $Models"
  Write-Host "   Provider : $(if ($Provider) { $Provider } else { '(auto)' })"
  Write-Host "   Protocol : $ApiType"
  if (-not $NoDefault) { Write-Host "   Default  : $(if ($DefaultModel) { $DefaultModel } else { '(provider/<first model>)' })" }
  Write-Host ''
  if (-not (Ask-Yes '7) Write this config?' 'n')) { Info 'cancelled'; exit 0 }
}

if (-not $SkipInstall) {
  $omoBin = Find-Omo
  if ($omoBin) {
    Info "omo already installed: $(& $omoBin --version 2>$null) - skipping installation"
  } else {
    if (Ask-Yes 'omo is not installed. Install it now?' 'y') { Install-Omo }
    else { Die 'omo is required; aborting' }
    $omoBin = Find-Omo
    if (-not $omoBin) { Die 'omo installed but not found on PATH; open a new terminal and re-run' }
    Info "installed: $(& $omoBin --version 2>$null)"
  }
} else {
  Info 'SkipInstall set, not checking installation'
}

if ($Interactive -or (-not $BaseUrl) -or (-not $ApiKey) -or (-not $Models)) { Invoke-Wizard }

$configArgs = @('--base-url', $BaseUrl, '--api-key', $ApiKey, '--models', $Models)
if ($Provider)     { $configArgs += @('--provider', $Provider) }
if ($ApiType)      { $configArgs += @('--api-type', $ApiType) }
if ($DefaultModel) { $configArgs += @('--default-model', $DefaultModel) }
if ($NoDefault)    { $configArgs += '--no-default' }
if ($DryRun)       { $configArgs += '--dry-run' }

function Get-ConfigScript {
  if ($ScriptDir) {
    $local = Join-Path $ScriptDir 'omo-config.mjs'
    if (Test-Path $local) { return $local }
  }
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("omo-config-{0}.mjs" -f ([Guid]::NewGuid().ToString('N')))
  Info 'downloading omo-config.mjs'
  try {
    Invoke-RestMethod -Uri "$RawBase/omo-config.mjs" -OutFile $tmp
  } catch {
    Die "failed to download omo-config.mjs: $($_.Exception.Message)"
  }
  return $tmp
}

$configScript = Get-ConfigScript

Info 'writing config'
if (Get-Command node -ErrorAction SilentlyContinue) { & node $configScript @configArgs }
elseif (Get-Command bun -ErrorAction SilentlyContinue) { & bun $configScript @configArgs }
else { Die 'need node or bun to write omo config' }
if ($LASTEXITCODE -ne 0) { Die "config step failed (exit $LASTEXITCODE)" }
