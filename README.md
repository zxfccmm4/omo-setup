# omo-setup

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)](#快速开始)
[![Shell](https://img.shields.io/badge/shell-bash%20%7C%20PowerShell-4EAA25)](./omo-setup.sh)

一键安装并配置 [OmO](https://omo.dev)（OmO Native / `omo` 命令）的跨平台脚本。

- **交互式**：直接运行，脚本一步一步引导你填写 base URL、API key、模型等，无需背命令。
- **智能检测**：已安装 `omo` 就跳过安装，未安装则询问后自动安装。
- **跨平台**：Linux / macOS 用 `omo-setup.sh`，Windows 用 `omo-setup.ps1`，配置逻辑共用 `omo-config.mjs`。

## 目录

- [快速开始](#快速开始)
- [脚本流程](#脚本流程)
- [写入的配置文件](#写入的配置文件)
- [非交互模式（脚本 / CI）](#非交互模式脚本--ci)
- [参数](#参数)
- [依赖](#依赖)
- [常见问题](#常见问题)
- [License](#license)

## 快速开始

### macOS / Linux

```bash
./omo-setup.sh
```

### Windows (PowerShell)

```powershell
.\omo-setup.ps1
```

运行后按提示逐步输入即可，每一步都显示 `[默认值]`，直接回车即采用默认：

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

## 脚本流程

1. **检测 omo**：在 `PATH` 中查找 `omo`（并兜底检查 `~/.bun/bin`、`~/.local/bin`、`~/.omo/bin` 等常见目录）。
   - 已安装 → 打印版本并**跳过**安装。
   - 未安装 → 询问是否安装，确认后运行官方安装脚本 `curl -fsSL https://get.omo.dev/install.sh | bash`（Windows：`irm https://get.omo.dev/install.ps1 | iex`）；失败时回退到 `bun add -g omo-ai` / `npm i -g omo-ai`。
2. **逐步配置**：依次询问 base URL、API key（隐藏输入）、模型列表、provider 名称、API 协议、默认模型，最后打印摘要并请求确认。
3. **写入配置**：确认后才写盘；输入 `n` 取消且不产生任何文件。

## 写入的配置文件

默认目录 `~/.omo/agent`（可用 `OMO_CODING_AGENT_DIR` 覆盖）。

`models.json` — 新增/更新 `providers.<名称>`：

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

`settings.json` — 设置默认模型：

```json
{
  "defaultProvider": "example-com",
  "defaultModel": "example-com/gpt-4o"
}
```

写入前会自动生成时间戳备份，并与已有 provider **合并**而非覆盖。

## 非交互模式（脚本 / CI）

一次性传入参数或环境变量，脚本会跳过向导：

```bash
./omo-setup.sh --base-url https://api.example.com/v1 --api-key sk-xxx --models gpt-4o,gpt-4o-mini
```

```bash
OMO_BASE_URL=https://api.example.com/v1 \
OMO_API_KEY=sk-xxx \
OMO_MODELS=gpt-4o \
./omo-setup.sh
```

```powershell
.\omo-setup.ps1 -BaseUrl https://api.example.com/v1 -ApiKey sk-xxx -Models gpt-4o,gpt-4o-mini
```

想强制运行向导，加 `-i` / `--interactive`（PowerShell：`-Interactive`）。

## 参数

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

## 依赖

- 配置写入需要 **Node.js >= 18** 或 **Bun**（脚本会自动选择可用的运行时）。
- 安装 omo 需要 `curl`（推荐）、或 `bun` / `npm`。

## 常见问题

**`omo` 装好了但提示找不到？**
新开的终端才能刷新 `PATH`。也可以手动执行 `export PATH="$HOME/.bun/bin:$PATH"`（或重启终端）后重试。

**想单独使用配置脚本，不走向导？**
直接调用共享脚本：

```bash
node omo-config.mjs --base-url https://api.example.com/v1 --api-key sk-xxx --models gpt-4o
```

**`--dry-run` 会写文件吗？**
不会。只打印将要写入的路径与内容摘要。

**配置文件在哪？**
默认 `~/.omo/agent`；可用环境变量 `OMO_CODING_AGENT_DIR`（旧版：`SENPI_CODING_AGENT_DIR` / `PI_CODING_AGENT_DIR`）覆盖。

## License

[MIT](./LICENSE)
