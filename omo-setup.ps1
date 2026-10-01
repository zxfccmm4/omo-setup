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
  [string]$Memory,
  [string]$OmoJson,
  [string[]]$Preset = @(),
  [string[]]$Category = @(),
  [string[]]$Agent = @(),
  [string[]]$TaskSetting = @(),
  [string[]]$Team = @(),
  [string[]]$SetJson = @(),
  [switch]$Advice,
  [switch]$NoAdvice,
  [switch]$NoAgentConfig,
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

function Ensure-Runtime {
  if (Get-Command node -ErrorAction SilentlyContinue) { return }
  if (Get-Command bun -ErrorAction SilentlyContinue) { return }

  Info 'node.js / bun not found; installing a JavaScript runtime automatically'

  if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
    }
    elseif (Get-Command choco -ErrorAction SilentlyContinue) {
      choco install nodejs-lts -y
    }
    elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
      scoop install nodejs-lts
    }
    else {
      Warn 'No supported package manager found for Node.js on Windows; trying Bun as fallback'
    }
  }
  elseif ($IsMacOS) {
    if (Get-Command brew -ErrorAction SilentlyContinue) {
      brew install node
    }
  }
  elseif (Get-Command apt-get -ErrorAction SilentlyContinue) {
    $sudo = $null
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and -not ($IsWindows)) {
      if (Get-Command sudo -ErrorAction SilentlyContinue) { $sudo = 'sudo' }
    }

    if ($sudo) { & $sudo apt-get update }
    else { apt-get update }

    if ($sudo) { & $sudo apt-get install -y ca-certificates curl gnupg }
    else { apt-get install -y ca-certificates curl gnupg }

    $keyring = '/etc/apt/keyrings/nodesource.gpg'
    $list = '/etc/apt/sources.list.d/nodesource.list'
    if (-not (Test-Path $keyring) -or -not (Test-Path $list)) {
      New-Item -ItemType Directory -Force -Path '/etc/apt/keyrings' | Out-Null
      $repoKey = (Invoke-WebRequest -Uri 'https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key' -UseBasicParsing).Content | Set-Content -Path $keyring -Encoding Byte
      @('deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main') | Set-Content -Path $list
    }

    if ($sudo) { & $sudo apt-get update; & $sudo apt-get install -y nodejs }
    else { apt-get update; apt-get install -y nodejs }
  }

  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    if (Get-Command curl -ErrorAction SilentlyContinue) {
      Info 'Falling back to Bun install'
      & curl -fsSL https://bun.sh/install.ps1 | powershell -c -
      if (Get-Command bun -ErrorAction SilentlyContinue) { return }
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
      winget install --id Oven-sh.Bun --accept-source-agreements --accept-package-agreements
    }
  }

  if (-not (Get-Command node -ErrorAction SilentlyContinue) -and -not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Die 'could not install node.js or bun automatically on this platform'
  }
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

  Write-Host ''
  if (Ask-Yes '8) Configure multi-agent features now (categories / agents / task / memory) into ~/.omo/omo.jsonc?' 'n') {
    Invoke-AgentWizard
  }
}

function Invoke-AgentWizard {
  Write-Host ''
  Info 'multi-agent setup (blank = keep current / skip)'
  Write-Host ''

  Write-Host '0) Start from an official example preset?'
  Write-Host '   1) claude-openai  2) kimi-glm  3) deepseek-alternative  4) none (default)'
  $v = Ask '   choose [1-4]' '4'
  switch ($v) {
    '1' { $script:Preset += 'claude-openai' }
    '2' { $script:Preset += 'kimi-glm' }
    '3' { $script:Preset += 'deepseek-alternative' }
  }

  $v = Ask 'a) Pin a task category as NAME=MODEL[:level] (e.g. quick=glm-5.3-flash)' $null
  while ($v) { $script:Category += $v; $v = Ask '   another category (blank = done)' $null }

  $v = Ask 'b) Pin an agent as NAME=MODEL[:level] (e.g. explore=deepseek-flash:high)' $null
  while ($v) { $script:Agent += $v; $v = Ask '   another agent (blank = done)' $null }

  $v = Ask 'c) Task engine setting as KEY=VALUE (e.g. default_concurrency=4)' $null
  while ($v) { $script:TaskSetting += $v; $v = Ask '   another task key (blank = done)' $null }

  $v = Ask 'd) Memory subsystem: 1) enable  2) disable  (blank = leave unchanged)' $null
  switch ($v) {
    '1' { $script:Memory = 'on' }
    '2' { $script:Memory = 'off' }
  }

  $v = Ask 'e) Define a team as NAME=JSON (blank = skip)' $null
  while ($v) { $script:Team += $v; $v = Ask '   another team (blank = done)' $null }
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

$haveAgentFlags = $NoAgentConfig -or $Preset.Count -or $Category.Count -or $Agent.Count -or $TaskSetting.Count -or $Team.Count -or $SetJson.Count -or $Memory -or $OmoJson
if ($Advice) { }
elseif ($Interactive) { Invoke-Wizard }
elseif ($BaseUrl -or $ApiKey -or $Models) {
  if (-not $BaseUrl -or -not $ApiKey -or -not $Models) { Invoke-Wizard }
}
elseif (-not $haveAgentFlags) { Invoke-Wizard }

$configArgs = @()
if ($BaseUrl -or $ApiKey -or $Models) {
  $configArgs += @('--base-url', $BaseUrl, '--api-key', $ApiKey, '--models', $Models)
}
if ($Provider)     { $configArgs += @('--provider', $Provider) }
if ($ApiType)      { $configArgs += @('--api-type', $ApiType) }
if ($DefaultModel) { $configArgs += @('--default-model', $DefaultModel) }
if ($NoDefault)    { $configArgs += '--no-default' }
if ($DryRun)       { $configArgs += '--dry-run' }
if (-not $NoAgentConfig) {
  foreach ($p in $Preset)      { $configArgs += @('--preset', $p) }
  foreach ($c in $Category)    { $configArgs += @('--category', $c) }
  foreach ($a in $Agent)       { $configArgs += @('--agent', $a) }
  foreach ($t in $TaskSetting) { $configArgs += @('--task', $t) }
  foreach ($t in $Team)        { $configArgs += @('--team', $t) }
  foreach ($j in $SetJson)     { $configArgs += @('--set-json', $j) }
  if ($Memory)  { $configArgs += @('--memory', $Memory) }
  if ($OmoJson) { $configArgs += @('--omo-json', $OmoJson) }
} else {
  $configArgs += '--no-agent-config'
}
if ($NoAdvice) { $configArgs += '--no-advice' }

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

if ($Advice) {
  Ensure-Runtime
  if (Get-Command node -ErrorAction SilentlyContinue) { & node $configScript --advice }
  elseif (Get-Command bun -ErrorAction SilentlyContinue) { & bun $configScript --advice }
  else { Die 'need node or bun to show recommendations' }
  exit $LASTEXITCODE
}

Ensure-Runtime
Info 'writing config'
if (Get-Command node -ErrorAction SilentlyContinue) { & node $configScript @configArgs }
elseif (Get-Command bun -ErrorAction SilentlyContinue) { & bun $configScript @configArgs }
else { Die 'need node or bun to write omo config' }
if ($LASTEXITCODE -ne 0) { Die "config step failed (exit $LASTEXITCODE)" }
