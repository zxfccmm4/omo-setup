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
  $v = Ask (Lc '   category name (e.g. quick, ultrabrain)' '   分类名称（例：quick、ultrabrain）') $null
  while ($v) {
    $spec = ''
    if ($list) { $spec = Select-OneModel $list }
    else { $spec = Ask (Lc '   model as provider/model[:level]' '   模型，格式 provider/model[:档位]') $null }
    if ($spec) { $script:Category += "$v=$spec" }
    $v = Ask (Lc '   another category (blank = done)' '   另一个分类（留空=完成）') $null
  }

  Write-Host (Lc 'b) Pin an agent (blank = skip)' 'b) 固定子代理的模型（留空=跳过）')
  $v = Ask (Lc '   agent name (e.g. explore, librarian)' '   子代理名称（例：explore、librarian）') $null
  while ($v) {
    $spec = ''
    if ($list) { $spec = Select-OneModel $list }
    else { $spec = Ask (Lc '   model as provider/model[:level]' '   模型，格式 provider/model[:档位]') $null }
    if ($spec) { $script:Agent += "$v=$spec" }
    $v = Ask (Lc '   another agent (blank = done)' '   另一个子代理（留空=完成）') $null
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
  try {
    Invoke-RestMethod -Uri "$RawBase/omo-config.mjs" -OutFile $tmp
  } catch {
    Die "failed to download omo-config.mjs: $($_.Exception.Message)"
  }
  return $tmp
}

function Get-RemoteModels {
  if (-not $BaseUrl) { return $null }
  $cfg = Get-ConfigScript
  $fetchArgs = @('--fetch-models', '--base-url', $BaseUrl, '--lang', $script:LangCode)
  if ($ApiKey) { $fetchArgs += @('--api-key', $ApiKey) }
  $raw = $null
  if (Get-Command node -ErrorAction SilentlyContinue) { $raw = & node $cfg @fetchArgs 2>$null }
  elseif (Get-Command bun -ErrorAction SilentlyContinue) { $raw = & bun $cfg @fetchArgs 2>$null }
  else { Die 'need node or bun to fetch models' }
  if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
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

function Select-Models($list) {
  Write-Host ''
  Write-Host (Lc "models from ${BaseUrl}:" "来自 ${BaseUrl} 的模型：")
  for ($i = 0; $i -lt [Math]::Min($list.Count, 60); $i++) {
    Write-Host ("   {0}) {1}`t{2}" -f ($i + 1), $list[$i].Id, $list[$i].Name)
  }
  if ($list.Count -gt 60) { Write-Host (Lc "   ... $($list.Count - 60) more" "   ... 还有 $($list.Count - 60) 个") }
  $input = Ask (Lc 'select: all / 1,3 / 2-4 (blank = all)' '请选择：all / 1,3 / 2-4（留空=全部）') ''
  if (-not $input -or $input -match '^(all|ALL)$') {
    return (($list | ForEach-Object { $_.Id }) -join ',')
  }
  $ids = @()
  foreach ($token in ($input -replace ',', ' ').Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)) {
    if ($token -match '^(\d+)-(\d+)$') {
      $a = [int]$Matches[1]; $b = [int]$Matches[2]
      for ($i = $a; $i -le $b; $i++) { if ($i -ge 1 -and $i -le $list.Count) { $ids += $list[$i - 1].Id } }
    } elseif ($token -match '^(\d+)$') {
      $i = [int]$Matches[1]
      if ($i -ge 1 -and $i -le $list.Count) { $ids += $list[$i - 1].Id }
    }
  }
  if ($ids.Count -eq 0) { return $null }
  return (($ids | Select-Object -Unique) -join ',')
}

function Select-OneModel($list) {
  Write-Host ''
  Write-Host (Lc 'pick a model:' '选择模型：')
  for ($i = 0; $i -lt [Math]::Min($list.Count, 60); $i++) {
    Write-Host ("   {0}) {1}`t{2}" -f ($i + 1), $list[$i].Id, $list[$i].Name)
  }
  $input = Ask (Lc 'model number (blank = skip)' '模型编号（留空=跳过）') ''
  if ($input -notmatch '^(\d+)$') { return $null }
  $i = [int]$Matches[1]
  if ($i -lt 1 -or $i -gt $list.Count) { return $null }
  $prov = Get-ProviderName
  if (-not $prov) { return $list[$i - 1].Id }
  return "$prov/$($list[$i - 1].Id)"
}

function Ask-Reasoning {
  return (Ask (Lc 'reasoning level: off|minimal|low|medium|high|xhigh|max (blank = default)' '推理档位：off|minimal|low|medium|high|xhigh|max（留空=默认）') '')
}

$configScript = Get-ConfigScript

if ($Advice) {
  if (Get-Command node -ErrorAction SilentlyContinue) { & node $configScript --advice }
  elseif (Get-Command bun -ErrorAction SilentlyContinue) { & bun $configScript --advice }
  else { Die 'need node or bun to show recommendations' }
  exit $LASTEXITCODE
}

Info 'writing config'
if (Get-Command node -ErrorAction SilentlyContinue) { & node $configScript @configArgs }
elseif (Get-Command bun -ErrorAction SilentlyContinue) { & bun $configScript @configArgs }
else { Die 'need node or bun to write omo config' }
if ($LASTEXITCODE -ne 0) { Die "config step failed (exit $LASTEXITCODE)" }
