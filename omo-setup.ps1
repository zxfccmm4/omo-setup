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
  [string]$ModelsFile,
  [string]$Lang     = $(if ($env:OMO_LANG) { $env:OMO_LANG } else { 'en' }),
  [ValidateSet('on','off','auto')]
  [string]$RecommendedWarning = 'auto',
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

# Language (en / zh): the wizard picks it first, --lang / OMO_LANG set the default.
$script:LangCode = 'en'
if ($Lang -match '^(zh|zh-cn|zh-hans|cn)$') { $script:LangCode = 'zh' }
elseif ($Lang -notmatch '^(en|en-us)$') { Write-Host "xx unknown -Lang '$Lang' (use en or zh)" -ForegroundColor Red; exit 1 }

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

# Lc 'english' '中文' - pick the string for the selected language.
function Lc($en, $zh) { if ($script:LangCode -eq 'zh') { return $zh } return $en }

function Select-Language {
  $default = if ($script:LangCode -eq 'zh') { '2' } else { '1' }
  Write-Host '0) Language / 语言:  1) English  2) 简体中文'
  $v = Ask (Lc '   choose [1-2]' '   请选择 [1-2]') $default
  if ($v -eq '2') { $script:LangCode = 'zh' } else { $script:LangCode = 'en' }
  Info (Lc 'language: English' '语言：简体中文')
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
  Select-Language
  Ensure-Runtime
  Write-Host ''
  Info (Lc 'step-by-step setup (press Enter to accept the [default])' '逐步配置（直接回车 = 采用 [默认值]）')
  Write-Host ''

  if (-not $BaseUrl) { $BaseUrl = Ask (Lc '1) Endpoint base URL (e.g. https://api.example.com/v1)' '1) 接口 base URL（例：https://api.example.com/v1）') $null }
  if (-not $BaseUrl) { Die (Lc 'base URL is required' 'base URL 必填') }

  if (-not $ApiKey) {
    $k = Ask-Secret (Lc '2) API key' '2) API key')
    if ($k) { $ApiKey = $k }
  }
  if (-not $ApiKey) { Die (Lc 'API key is required' 'API key 必填') }

  # Try the endpoint's /models listing first; fall back to typing ids by hand.
  if (-not $Models -and -not $ModelsFile) {
    Info (Lc 'fetching the model list from the endpoint...' '正在从端点获取模型列表...')
    $list = Get-RemoteModels
    if ($list) {
      Info (Lc "found $($list.Count) models" "共发现 $($list.Count) 个模型")
      $picked = Select-Models $list
      if ($picked) { $Models = $picked }
    } else {
      Warn (Lc 'falling back to typing model ids by hand' '改用手动输入模型 id')
    }
  }
  if (-not $Models -and -not $ModelsFile) {
    $Models = Ask (Lc '3) Model ids, comma-separated (e.g. gpt-4o,gpt-4o-mini)' '3) 模型 id，逗号分隔（例：gpt-4o,gpt-4o-mini）') $null
    if (-not $Models) { Die (Lc 'at least one model is required' '至少需要一个模型') }
  }

  $Provider = Ask (Lc '4) Provider name (blank = auto from host)' '4) Provider 名称（留空 = 由域名自动推导）') $Provider

  Write-Host (Lc '5) API protocol:  1) openai-completions (default)  2) openai-responses  3) anthropic-messages' '5) API 协议：1) openai-completions（默认） 2) openai-responses 3) anthropic-messages')
  $choice = Ask (Lc '   choose [1-3]' '   请选择 [1-3]') '1'
  switch ($choice) {
    '2' { $ApiType = 'openai-responses' }
    '3' { $ApiType = 'anthropic-messages' }
    '1' { $ApiType = 'openai-completions' }
    default { Warn (Lc "unknown choice '$choice', using openai-completions" "未知选项 '$choice'，改用 openai-completions"); $ApiType = 'openai-completions' }
  }

  $DefaultModel = Ask (Lc '6) Default model (blank = provider/<first model>)' '6) 默认模型（留空 = provider/<第一个模型>）') $DefaultModel

  Write-Host ''
  Info (Lc 'about to write:' '即将写入：')
  Write-Host "   Base URL : $BaseUrl"
  Write-Host "   API key  : $(Mask $ApiKey)"
  Write-Host "   Models   : $(if ($Models) { $Models } else { '(from file)' })"
  Write-Host "   Provider : $(if ($Provider) { $Provider } else { '(auto)' })"
  Write-Host "   Protocol : $ApiType"
  if (-not $NoDefault) { Write-Host "   Default  : $(if ($DefaultModel) { $DefaultModel } else { '(provider/<first model>)' })" }
  Write-Host ''
  if (-not (Ask-Yes (Lc '7) Write this config?' '7) 写入以上配置？') 'n')) { Info (Lc 'cancelled' '已取消'); exit 0 }

  Write-Host ''
  if (Ask-Yes (Lc '8) Configure multi-agent features now (categories / agents / task / memory) into ~/.omo/omo.jsonc?' '8) 现在配置多智能体（任务分类 / 子代理 / 任务引擎 / 记忆）并写入 ~/.omo/omo.jsonc？') 'n') {
    Invoke-AgentWizard
  }
}

function Invoke-AgentWizard {
  Write-Host ''
  Info (Lc 'multi-agent setup (blank = keep current / skip)' '多智能体配置（留空 = 保持现状 / 跳过）')
  Write-Host ''

  Write-Host (Lc '0) Start from an official example preset?' '0) 从官方示例预设开始？')
  Write-Host (Lc '   1) claude-openai  2) kimi-glm  3) deepseek-alternative  4) none (default)' '   1) claude-openai  2) kimi-glm  3) deepseek-alternative  4) 不使用（默认）')
  $v = Ask (Lc '   choose [1-4]' '   请选择 [1-4]') '4'
  switch ($v) {
    '1' { $script:Preset += 'claude-openai' }
    '2' { $script:Preset += 'kimi-glm' }
    '3' { $script:Preset += 'deepseek-alternative' }
  }

  # Offer the endpoint's model list for picking, so users type fewer ids.
  $list = $null
  if ($BaseUrl) {
    $list = Get-RemoteModels
    if ($list) { Info (Lc "found $($list.Count) models on the endpoint" "在端点上发现 $($list.Count) 个模型") }
  }

  Write-Host (Lc 'a) Pin a task category (blank = skip)' 'a) 固定任务分类的模型（留空=跳过）')
  $v = Ask (Lc '   add a category? [y/N]' '   要固定分类吗？[y/N]') 'n'
  if ($v -notmatch '^(y|yes)$') { $v = $null } else { $v = Pick-Name 'category' }
  while ($v) {
    $spec = ''
    if ($list) { $spec = Select-OneModel $list }
    else { $spec = Ask (Lc '   model as provider/model[:level]' '   模型，格式 provider/model[:档位]') $null }
    if ($spec) { $script:Category += "$v=$spec" }
    $v = Ask (Lc '   another category? [y/N]' '   还要固定其他分类吗？[y/N]') 'n'
    if ($v -match '^(y|yes)$') { $v = Pick-Name 'category' } else { $v = $null }
  }

  Write-Host (Lc 'b) Pin an agent (blank = skip)' 'b) 固定子代理的模型（留空=跳过）')
  $v = Ask (Lc '   add an agent? [y/N]' '   要固定子代理吗？[y/N]') 'n'
  if ($v -notmatch '^(y|yes)$') { $v = $null } else { $v = Pick-Name 'agent' }
  while ($v) {
    $spec = ''
    if ($list) { $spec = Select-OneModel $list }
    else { $spec = Ask (Lc '   model as provider/model[:level]' '   模型，格式 provider/model[:档位]') $null }
    if ($spec) { $script:Agent += "$v=$spec" }
    $v = Ask (Lc '   another agent? [y/N]' '   还要固定其他子代理吗？[y/N]') 'n'
    if ($v -match '^(y|yes)$') { $v = Pick-Name 'agent' } else { $v = $null }
  }

  $v = Ask (Lc 'c) Task engine setting as KEY=VALUE (e.g. default_concurrency=4)' 'c) 任务引擎设置 KEY=VALUE（例：default_concurrency=4）') $null
  while ($v) { $script:TaskSetting += $v; $v = Ask (Lc '   another task key (blank = done)' '   另一个任务键（留空=完成）') $null }

  $v = Ask (Lc 'd) Memory subsystem: 1) enable  2) disable  (blank = leave unchanged)' 'd) 记忆子系统：1) 开启  2) 关闭（留空=不变）') $null
  switch ($v) {
    '1' { $script:Memory = 'on' }
    '2' { $script:Memory = 'off' }
  }

  $v = Ask (Lc 'e) Define a team as NAME=JSON (blank = skip)' 'e) 定义团队 NAME=JSON（留空=跳过）') $null
  while ($v) { $script:Team += $v; $v = Ask (Lc '   another team (blank = done)' '   另一个团队（留空=完成）') $null }
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
elseif ($BaseUrl -or $ApiKey -or $Models -or $ModelsFile) {
  if (-not $Models -and -not $ModelsFile) { Invoke-Wizard }
  if (-not $BaseUrl -or -not $ApiKey) { Invoke-Wizard }
}
elseif (-not $haveAgentFlags) { Invoke-Wizard }

$configArgs = @()
if ($BaseUrl -or $ApiKey -or $Models -or $ModelsFile) {
  $configArgs += @('--base-url', $BaseUrl, '--api-key', $ApiKey)
  if ($ModelsFile) { $configArgs += @('--models-file', $ModelsFile) }
  else { $configArgs += @('--models', $Models) }
}
$configArgs += @('--lang', $script:LangCode)
$configArgs += @('--recommended-warning', $RecommendedWarning)
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
  $urls = @("$RawBase/omo-config.mjs", 'https://cdn.jsdelivr.net/gh/zxfccmm4/omo-setup@main/omo-config.mjs')
  foreach ($url in $urls) {
    try {
      Invoke-RestMethod -Uri $url -OutFile $tmp -TimeoutSec 120
      if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) { return $tmp }
    } catch {
      Warn "download failed from $url : $($_.Exception.Message)"
    }
  }
  Die 'failed to download omo-config.mjs (tried raw.githubusercontent.com and cdn.jsdelivr.net)'
}

function Get-RemoteModels {
  if (-not $BaseUrl) { return $null }
  $cfg = Get-ConfigScript
  $fetchArgs = @('--fetch-models', '--base-url', $BaseUrl, '--lang', $script:LangCode)
  if ($ApiKey) { $fetchArgs += @('--api-key', $ApiKey) }
  $errFile = [System.IO.Path]::GetTempFileName()
  $raw = $null
  try {
    if (Get-Command node -ErrorAction SilentlyContinue) { $raw = & node $cfg @fetchArgs 2>$errFile }
    elseif (Get-Command bun -ErrorAction SilentlyContinue) { $raw = & bun $cfg @fetchArgs 2>$errFile }
    else { Die 'need node or bun to fetch models' }
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
      $why = (Get-Content -Path $errFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 1)
      if ($why) { Warn $why }
      return $null
    }
  } finally {
    Remove-Item -Path $errFile -Force -ErrorAction SilentlyContinue
  }
  $out = @()
  foreach ($line in @($raw)) {
    if (-not $line) { continue }
    $parts = $line -split "`t", 2
    $id = $parts[0].Trim()
    if (-not $id) { continue }
    $name = if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { $id }
    $out += [pscustomobject]@{ Id = $id; Name = $name }
  }
  if ($out.Count -eq 0) { return $null }
  return $out
}

function Get-ProviderName {
  if ($Provider) { return $Provider }
  if (-not $BaseUrl) { return $null }
  $cfg = Get-ConfigScript
  $out = & node $cfg --print-provider --base-url $BaseUrl --lang $script:LangCode 2>$null
  if ($LASTEXITCODE -eq 0 -and $out) { $script:Provider = ($out | Select-Object -First 1).Trim() }
  return $script:Provider
}

function Build-View($list, $filter) {
  if (-not $filter) { return @($list) }
  return @($list | Where-Object { "$($_.Id) $($_.Name)" -like "*$filter*" })
}

function Pick-Name($kind) {
  if ($kind -eq 'category') {
    $names = @('architect','artistry','quick','deep-low','deep-high','ultrabrain','unspecified-low','unspecified-high','visual-engineering','writing')
  } else {
    $names = @('explore','librarian','plan-consultant','plan-reviewer')
  }
  Write-Host (Lc '   built-in names:' '   内置名称：')
  for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("     {0}) {1}" -f ($i + 1), $names[$i]) }
  Write-Host (Lc '0) type a custom name' '0) 手动输入名称')
  $input = Ask (Lc '   choose [0-N]' '   请选择 [0-N]') '0'
  if ($input -match '^(\d+)$') {
    $i = [int]$input
    if ($i -ge 1 -and $i -le $names.Count) { return $names[$i - 1] }
  }
  if ($input -and $input -notmatch '^(0|\d+)$') { return $input }
  return (Ask (Lc '   name' '   名称') $null)
}

function Show-View($view, $max) {
  for ($i = 0; $i -lt [Math]::Min($view.Count, $max); $i++) {
    Write-Host ("   {0}) {1}`t{2}" -f ($i + 1), $view[$i].Id, $view[$i].Name)
  }
  if ($view.Count -gt $max) {
    Write-Host (Lc "   ... $($view.Count - $max) more - type text to filter, or r for the full list" "   还有 $($view.Count - $max) 个 - 输入文字过滤，或输入 r 显示全部")
  }
  Write-Host (Lc "   ($($view.Count) shown)" "   （共 $($view.Count) 个）")
}

function Select-Models($list) {
  $filter = ''
  while ($true) {
    $view = Build-View $list $filter
    if ($view.Count -eq 0) { Warn (Lc 'nothing matched that filter' '没有匹配的模型'); $filter = ''; continue }
    Write-Host ''
    Write-Host (Lc "models from ${BaseUrl}:" "来自 ${BaseUrl} 的模型：")
    Show-View $view 60
    $input = Ask (Lc 'select: all / 1,3 / 2-4 / text filter (blank = all)' '请选择：all / 1,3 / 2-4 / 过滤词（留空=全部）') ''
    if (-not $input -or $input -match '^(all|ALL)$') {
      return (($view | ForEach-Object { $_.Id }) -join ',')
    }
    $ids = @()
    $valid = $true
    foreach ($token in ($input -replace ',', ' ').Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)) {
      if ($token -match '^(\d+)-(\d+)$') {
        $a = [int]$Matches[1]; $b = [int]$Matches[2]
        if ($a -lt 1 -or $b -gt $view.Count -or $a -gt $b) { $valid = $false; break }
        for ($i = $a; $i -le $b; $i++) { $ids += $view[$i - 1].Id }
      } elseif ($token -match '^(\d+)$') {
        $i = [int]$Matches[1]
        if ($i -lt 1 -or $i -gt $view.Count) { $valid = $false; break }
        $ids += $view[$i - 1].Id
      } else {
        $valid = $false
        break
      }
    }
    if (-not $valid -or $ids.Count -eq 0) {
      if ($valid) { $filter = $input } else { Warn (Lc "invalid selection '$input'" "无效的选择 '$input'") }
      continue
    }
    return (($ids | Select-Object -Unique) -join ',')
  }
}

function Select-OneModel($list) {
  $filter = ''
  $max = 15
  while ($true) {
    $view = Build-View $list $filter
    if ($view.Count -eq 0) { Warn (Lc 'nothing matched that filter' '没有匹配的模型'); $filter = ''; continue }
    Write-Host ''
    Write-Host (Lc 'pick a model:' '选择模型：')
    Show-View $view $max
    $input = Ask (Lc 'number / text to filter / r = all / blank = skip' '编号 / 文字过滤 / r 全部 / 留空跳过') ''
    if (-not $input) { return $null }
    if ($input -match '^(r|R|all|ALL)$') { $max = 200; continue }
    if ($input -notmatch '^(\d+)$') { $filter = $input; continue }
    $i = [int]$input
    if ($i -lt 1 -or $i -gt $view.Count) { Warn (Lc "invalid number '$input'" "无效编号 '$input'"); continue }
    $prov = Get-ProviderName
    if (-not $prov) { return $view[$i - 1].Id }
    return "$prov/$($view[$i - 1].Id)"
  }
}

function Ask-Reasoning {
  return (Ask (Lc 'reasoning level: off|minimal|low|medium|high|xhigh|max (blank = default)' '推理档位：off|minimal|low|medium|high|xhigh|max（留空=默认）') '')
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
