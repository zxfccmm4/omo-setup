<div align="center">

# omo-setup

**一键安装并配置 [OmO](https://omo.dev) 的跨平台脚本。**

跑一条命令，剩下的交给向导 —— 检测、安装、填写 base URL / API key / 模型，全程有提示，无需背参数。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)](#-快速开始)
[![Shell](https://img.shields.io/badge/shell-bash%20%7C%20PowerShell-4EAA25)](./omo-setup.sh)
[![Node](https://img.shields.io/badge/node-%3E%3D18-339933)](https://nodejs.org)

</div>

---

## ✨ 特性

| 特性 | 说明 |
| --- | --- |
| 🧭 **交互式** | 直接运行即可，脚本逐步引导你填写 base URL、API key、模型等，无需记命令。 |
| 🤖 **多智能体** | 可选配置 OmO 的任务分类、子代理、任务引擎、记忆与团队（写入 `~/.omo/omo.jsonc`）。 |
| 🔍 **智能检测** | 已安装 `omo` 就跳过安装；未安装则询问后自动安装。 |
| 🖥️ **跨平台** | Linux / macOS 用 `omo-setup.sh`，Windows 用 `omo-setup.ps1`，配置逻辑共用 `omo-config.mjs`。 |
| 🔒 **安全写入** | 确认后才写盘，自动备份原配置，并与已有 provider **合并**而非覆盖。 |

## 📑 目录

- [快速开始](#-快速开始)
- [脚本流程](#-脚本流程)
- [写入的配置文件](#-写入的配置文件)
- [多智能体配置](#-多智能体配置)
- [非交互模式（脚本 / CI）](#-非交互模式脚本--ci)
- [参数](#-参数)
- [依赖](#-依赖)
- [常见问题](#-常见问题)
- [License](#license)

## 🚀 快速开始

### 远程一键运行（推荐）

无需先下载，直接下载并执行脚本：

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/omo-setup/main/omo-setup.sh | bash
```

**Windows（PowerShell）**

```powershell
irm https://raw.githubusercontent.com/zxfccmm4/omo-setup/main/omo-setup.ps1 | iex
```

> 脚本运行时会自动下载配套的 `omo-config.mjs`（无需手动准备），并在当前终端逐步提示输入。

### 本地运行

先克隆仓库再执行：

```bash
git clone https://github.com/zxfccmm4/omo-setup && cd omo-setup
./omo-setup.sh
```

```powershell
git clone https://github.com/zxfccmm4/omo-setup && cd omo-setup
.\omo-setup.ps1
```

### 按提示逐步输入

每一步都显示 `[默认值]`，直接回车即采用默认：

```
==> step-by-step setup (press Enter to accept the [default])

1) Endpoint base URL (e.g. https://api.example.com/v1): https://api.example.com/v1
2) API key:                       # 输入隐藏，不回显
3) Model ids, comma-separated (e.g. gpt-4o,gpt-4o-mini): gpt-4o,gpt-4o-mini
4) Provider name (blank = auto from host):
5) API protocol:  1) openai-completions (default)  2) openai-responses  3) anthropic-messages
   choose [1-3] [1]:
6) Default model (blank = provider/<first model>):

==> about to write:
   Base URL : https://api.example.com/v1
   API key  : sk-a...-4f2c
   Models   : gpt-4o,gpt-4o-mini
   Provider : (auto)
   Protocol : openai-completions
   Default  : (provider/<first model>)

7) Write this config? [n]: y
==> writing config
provider   : example-com
baseUrl    : https://api.example.com/v1
...
omo config updated.
```

## 🔧 脚本流程

1. **检测 omo** —— 在 `PATH` 中查找 `omo`（并兜底检查 `~/.bun/bin`、`~/.local/bin`、`~/.omo/bin` 等常见目录）。
   - 已安装 → 打印版本并**跳过**安装。
   - 未安装 → 询问是否安装，确认后运行官方安装脚本 `curl -fsSL https://get.omo.dev/install.sh | bash`（Windows：`irm https://get.omo.dev/install.ps1 | iex`）；失败时回退到 `bun add -g omo-ai` / `npm i -g omo-ai`。
2. **逐步配置** —— 依次询问 base URL、API key（隐藏输入）、模型列表、provider 名称、API 协议、默认模型，最后打印摘要并请求确认。
3. **写入配置** —— 确认后才写盘；输入 `n` 取消且不产生任何文件。

## 📦 写入的配置文件

默认目录 `~/.omo/agent`（可用 `OMO_CODING_AGENT_DIR` 覆盖）。

`models.json` —— 新增/更新 `providers.<名称>`：

```json
{
  "providers": {
    "example-com": {
      "baseUrl": "https://api.example.com/v1",
      "api": "openai-completions",
      "apiKey": "sk-xxx",
      "models": [{ "id": "gpt-4o", "name": "gpt-4o" }]
    }
  }
}
```

`settings.json` —— 设置默认模型：

```json
{
  "defaultProvider": "example-com",
  "defaultModel": "example-com/gpt-4o"
}
```

> 写入前会自动生成时间戳备份，并与已有 provider **合并**而非覆盖。

## 🤖 多智能体配置

除了 provider，脚本还能把 OmO 的多智能体功能写进 `~/.omo/omo.jsonc`（该文件在 OmO 根目录，是 `agent/` 的上一级）。向导第 8 步会询问是否配置，非交互模式则用下面的参数。

### 先看官方建议

脚本内置了官方 [Agent-Model Matching 指南](https://github.com/code-yeongyu/oh-my-openagent/blob/dev/docs/guide/agent-model-matching.md) 的摘要，随时可查：

```bash
./omo-setup.sh --advice
```

核心结论（**大多数人不配也能用**，OmO Native 会自动为每个分类和代理选模型）：

- **主代理推荐梯队**（按优先级）：Claude Opus 5.5 → Claude Fable 5.1 → Kimi K3 → GPT-6 Astra → GPT-6.1 Sol → GPT-6 Sol → GLM 5.3。梯队外的模型官方不保证。
- **模型家族要对得上角色**：Claude 系 → 主代理与 `plan-consultant`；GPT 系 → `plan-reviewer`、`ultrabrain`、`deep-low`、`deep-high`；小而快的模型 → `explore`、`librarian`、`quick`。
- **别把贵模型放错位置**：`explore`/`librarian` 用 Opus/Fable 是巨大的浪费；`plan-reviewer` 用小模型会沦为橡皮图章。
- 配置时脚本会自动检查这些**风险组合**并打印 `advice:` 提示（用 `--no-advice` 关闭）。

### 从官方示例起步（presets）

内置三个官方示例，可直接当模板再微调 provider 前缀：

```bash
./omo-setup.sh --preset claude-openai        # 官方 Example A：Claude + OpenAI
./omo-setup.sh --preset kimi-glm             # 官方 Example B：Kimi/GLM 接管 Claude 类角色
./omo-setup.sh --preset deepseek-alternative # 官方 Example C：DeepSeek 作 GPT 备用链
```

preset 与你自己的参数可以叠加，且**你的显式指定优先**：

```bash
./omo-setup.sh --preset claude-openai --category deep-high=anthropic/claude-opus-5-5:max
```

向导第 8 步的第一步（`0)`）也会询问是否选用某个 preset。

只写了多智能体参数、没写 provider 参数时，脚本会跳过 provider 向导，只更新 `omo.jsonc`。

**任务分类（categories）** —— 给某一类任务指定模型与推理档位：

```bash
./omo-setup.sh --category architect=anthropic/claude-opus-5-5:max \
               --category quick=glm-5.3-flash
```

**子代理（agents）** —— 覆盖内置代理（`explore` / `librarian` / `plan-consultant` / `plan-reviewer`）：

```bash
./omo-setup.sh --agent explore=deepseek-flash:high
```

**任务引擎（task）** —— 并发数、最大深度、执行模式等：

```bash
./omo-setup.sh --task default_concurrency=4 --task max_depth=2 \
               --task 'wait={"default_ms":90000}'
```

**记忆与团队** —— 开关记忆子系统，或定义团队：

```bash
./omo-setup.sh --memory on \
  --team 'reviewers={"leadAgentId":"lead","members":[{"kind":"category","name":"quick","category":"deep-low","prompt":"Review the diff."}]}'
```

**任意字段** —— 用 `--set-json` 或 `--omo-json <文件>` 深度合并任意合法配置：

```bash
./omo-setup.sh --set-json '{"git_master":{"commit_footer":true}}'
./omo-setup.sh --omo-json ./my-omo.jsonc
```

写入时会读取现有 `omo.jsonc`（支持 `//` 注释与尾逗号）并**深度合并**：同名对象递归合并，数组/标量整体替换；写入前自动备份为 `omo.jsonc.bak.<时间戳>`。若只想配 provider，加 `--no-agent-config` 即可完全不碰 `omo.jsonc`。

生成的配置符合 [OmO 官方 schema](https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/omo.schema.json)，文件顶部会自动补上 `$schema` 以便编辑器提示。

## 🤖 非交互模式（脚本 / CI）

一次性传入参数或环境变量，脚本会跳过向导：

**命令行参数**

```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/omo-setup/main/omo-setup.sh | bash -s -- \
  --base-url https://api.example.com/v1 --api-key sk-xxx --models gpt-4o,gpt-4o-mini
```

**环境变量**

```bash
OMO_BASE_URL=https://api.example.com/v1 \
OMO_API_KEY=sk-xxx \
OMO_MODELS=gpt-4o \
./omo-setup.sh
```

**Windows（PowerShell）**

```powershell
.\omo-setup.ps1 -BaseUrl https://api.example.com/v1 -ApiKey sk-xxx -Models gpt-4o,gpt-4o-mini
```

> 想强制运行向导，加 `-i` / `--interactive`（PowerShell：`-Interactive`）。

## 📋 参数

| 参数 | 环境变量 | 说明 |
| --- | --- | --- |
| `-i`, `--interactive` / `-Interactive` | — | 强制运行交互向导（即使已提供参数） |
| `--base-url` / `-BaseUrl` | `OMO_BASE_URL` | 接口 base URL |
| `--api-key` / `-ApiKey` | `OMO_API_KEY` | API key |
| `--models` / `-Models` | `OMO_MODELS` | 逗号分隔的模型 id 列表 |
| `--provider` / `-Provider` | `OMO_PROVIDER` | provider 名称，默认从域名推导 |
| `--api-type` / `-ApiType` | `OMO_API_TYPE` | `openai-completions`（默认）\| `openai-responses` \| `anthropic-messages` |
| `--default-model` / `-DefaultModel` | `OMO_DEFAULT_MODEL` | 默认模型，默认 `provider/<第一个模型>` |
| `--no-default` / `-NoDefault` | — | 不修改 `settings.json` 的默认模型 |
| `--dry-run` / `-DryRun` | — | 只打印将要做的改动，不写盘 |
| `--skip-install` / `-SkipInstall` | — | 只配置，不做安装检测 |
| `--allow-root` | `OMO_INSTALL_ALLOW_SUDO=1` | 允许以 root 安装 omo（仅 `omo-setup.sh`） |
| `--category` / `-Category` | — | 固定任务分类，`NAME=MODEL[:LEVEL]`，可重复 |
| `--agent` / `-Agent` | — | 固定子代理模型，`NAME=MODEL[:LEVEL]`，可重复 |
| `--task` / `-TaskSetting` | — | 设置任务引擎键值，`KEY=VALUE`，可重复 |
| `--memory` / `-Memory` | — | 开关记忆子系统，`on` \| `off` |
| `--team` / `-Team` | — | 定义团队，`NAME=JSON`，可重复 |
| `--set-json` / `-SetJson` | — | 深度合并任意 JSON 片段，可重复 |
| `--omo-json` / `-OmoJson` | — | 深度合并一个 JSON/JSONC 文件 |
| `--no-agent-config` / `-NoAgentConfig` | — | 完全不修改 `omo.jsonc` |
| `--advice` / `-Advice` | — | 打印官方多智能体推荐并退出 |
| `--preset` / `-Preset` | — | 从官方示例起步：`claude-openai` \| `kimi-glm` \| `deepseek-alternative`，可重复 |
| `--no-advice` / `-NoAdvice` | — | 关闭风险组合提示 |

## 🧩 依赖

- 配置写入需要 **Node.js >= 18** 或 **Bun**（脚本会自动选择可用的运行时）。
- 安装 omo 需要 `curl`（推荐）、或 `bun` / `npm`。

## ❓ 常见问题

<details>
<summary><b>远程执行时 API key 输入会卡住？</b></summary>

向导从 `/dev/tty` 读取输入，因此 `curl | bash` 也能正常交互。若在无终端的 CI 环境运行，请改用非交互模式传入 `--base-url/--api-key/--models`。

</details>

<details>
<summary><b>以 root 运行时报 <code>refusing to run as root</code>？</b></summary>

omo 官方安装器默认拒绝 root。脚本会检测到这一点并提示：可确认后自动加上 `OMO_INSTALL_ALLOW_SUDO=1` 继续安装，或改用非 root 用户运行。非交互场景直接传 `--allow-root`（等价于 `OMO_INSTALL_ALLOW_SUDO=1`）：

```bash
curl -fsSL https://raw.githubusercontent.com/zxfccmm4/omo-setup/main/omo-setup.sh | bash -s -- --allow-root
```

注意：以 root 安装会把配置写到 `/root/.omo`；多用户机器更推荐用普通用户运行。

</details>

<details>
<summary><b><code>omo</code> 装好了但提示找不到？</b></summary>

新开的终端才能刷新 `PATH`。也可以手动执行 `export PATH="$HOME/.bun/bin:$PATH"`（或重启终端）后重试。

</details>

<details>
<summary><b>想单独使用配置脚本，不走向导？</b></summary>

直接调用共享脚本：

```bash
node omo-config.mjs --base-url https://api.example.com/v1 --api-key sk-xxx --models gpt-4o
```

</details>

<details>
<summary><b><code>--dry-run</code> 会写文件吗？</b></summary>

不会。只打印将要写入的路径与内容摘要。

</details>

<details>
<summary><b>配置文件在哪？</b></summary>

默认 `~/.omo/agent`；可用环境变量 `OMO_CODING_AGENT_DIR`（旧版：`SENPI_CODING_AGENT_DIR` / `PI_CODING_AGENT_DIR`）覆盖。多智能体配置写在 `~/.omo/omo.jsonc`，可用 `OMO_OMO_JSONC` 覆盖路径。

</details>

## License

[MIT](./LICENSE)
