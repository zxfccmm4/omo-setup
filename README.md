# omo-setup

一键安装并配置 [OmO](https://omo.dev)（OmO Native / `omo` 命令）的跨平台脚本。

- **检测**：已安装 `omo` 就跳过安装，未安装则自动安装。
- **配置**：一条命令写入自定义 provider 的 `baseUrl` + `apiKey` + 模型列表，并设为默认模型。
- **跨平台**：Linux / macOS 用 `omo-setup.sh`，Windows 用 `omo-setup.ps1`，配置逻辑共用 `omo-config.mjs`。

## 快速开始

### macOS / Linux

```bash
./omo-setup.sh --base-url https://api.example.com/v1 --api-key sk-xxx --models gpt-4o,gpt-4o-mini
```

或用环境变量：

```bash
OMO_BASE_URL=https://api.example.com/v1 \
OMO_API_KEY=sk-xxx \
OMO_MODELS=gpt-4o \
./omo-setup.sh
```

### Windows (PowerShell)

```powershell
.\omo-setup.ps1 -BaseUrl https://api.example.com/v1 -ApiKey sk-xxx -Models gpt-4o,gpt-4o-mini
```

或用环境变量：

```powershell
$env:OMO_BASE_URL="https://api.example.com/v1"
$env:OMO_API_KEY="sk-xxx"
$env:OMO_MODELS="gpt-4o"
.\omo-setup.ps1
```

## 它做了什么

1. **检测 omo**：在 `PATH` 中查找 `omo`（并兜底检查 `~/.bun/bin`、`~/.local/bin`、`~/.omo/bin` 等常见目录）。
   - 已安装 → 打印版本并**跳过**安装。
   - 未安装 → 运行官方安装脚本 `curl -fsSL https://get.omo.dev/install.sh | bash`（Windows：`irm https://get.omo.dev/install.ps1 | iex`）；失败时回退到 `bun add -g omo-ai` / `npm i -g omo-ai`。
2. **写入配置**：
   - `~/.omo/agent/models.json` → 新增/更新 `providers.<名称>`：`{ baseUrl, api, apiKey, models[] }`
   - `~/.omo/agent/settings.json` → 设置 `defaultProvider` / `defaultModel`
   - 写入前自动生成时间戳备份；与已有 provider **合并**而非覆盖。

## 参数

| 参数 | 环境变量 | 说明 |
| --- | --- | --- |
| `--base-url` | `OMO_BASE_URL` | 接口 base URL（必填） |
| `--api-key` | `OMO_API_KEY` | API key（必填） |
| `--models` | `OMO_MODELS` | 逗号分隔的模型 id 列表（必填） |
| `--provider` | `OMO_PROVIDER` | provider 名称，默认从域名推导 |
| `--api-type` | `OMO_API_TYPE` | `openai-completions`（默认）\| `openai-responses` \| `anthropic-messages` |
| `--default-model` | `OMO_DEFAULT_MODEL` | 默认模型，默认 `provider/<第一个模型>` |
| `--no-default` | — | 不修改 `settings.json` 的默认模型 |
| `--dry-run` | — | 只打印将要做的改动，不写盘 |
| `--skip-install` | — | 只配置，不做安装检测 |

PowerShell 版本使用对应参数名：`-BaseUrl`、`-ApiKey`、`-Models`、`-Provider`、`-ApiType`、`-DefaultModel`、`-NoDefault`、`-DryRun`、`-SkipInstall`。

## 依赖

- 配置写入需要 **Node.js >= 18** 或 **Bun**（脚本会自动选择可用的运行时）。
- 安装 omo 需要 `curl`（推荐）、或 `bun` / `npm`。

## 配置文件位置

默认目录 `~/.omo/agent`，可用环境变量覆盖：`OMO_CODING_AGENT_DIR`（旧版：`SENPI_CODING_AGENT_DIR` / `PI_CODING_AGENT_DIR`）。

## 单独使用配置脚本

也可以不经过安装脚本，直接用 `omo-config.mjs`：

```bash
node omo-config.mjs --base-url https://api.example.com/v1 --api-key sk-xxx --models gpt-4o
```

## License

MIT
