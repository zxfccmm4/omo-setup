# omo-setup

一键安装并配置 [OmO](https://omo.dev)（OmO Native / `omo` 命令）的跨平台脚本。

- **交互式**：直接运行，脚本会一步一步引导你填写 base URL、API key、模型等，无需背命令。
- **检测**：已安装 `omo` 就跳过安装，未安装则询问后自动安装。
- **跨平台**：Linux / macOS 用 `omo-setup.sh`，Windows 用 `omo-setup.ps1`，配置逻辑共用 `omo-config.mjs`。

## 快速开始

### macOS / Linux

```bash
./omo-setup.sh
```

然后按提示逐步输入即可：

```
==> step-by-step setup (press Enter to accept the [default])

1) Endpoint base URL (e.g. https://api.example.com/v1):
2) API key:
3) Model ids, comma-separated (e.g. gpt-4o,gpt-4o-mini):
4) Provider name (blank = auto from host):
5) API protocol:  1) openai-completions (default)  2) openai-responses  3) anthropic-messages
   choose [1-3] [1]:
6) Default model (blank = provider/<first model>):
7) Write this config? [n]:
```

### Windows (PowerShell)

```powershell
.\omo-setup.ps1
```

步骤与上面完全一致。

## 脚本流程

1. **检测 omo**：在 `PATH` 中查找 `omo`（并兜底检查 `~/.bun/bin`、`~/.local/bin`、`~/.omo/bin` 等常见目录）。
   - 已安装 → 打印版本并**跳过**安装。
   - 未安装 → 询问是否安装，确认后运行官方安装脚本 `curl -fsSL https://get.omo.dev/install.sh | bash`（Windows：`irm https://get.omo.dev/install.ps1 | iex`）；失败时回退到 `bun add -g omo-ai` / `npm i -g omo-ai`。
2. **逐步配置**（交互向导）：依次询问 base URL、API key（输入隐藏）、模型列表、provider 名称、API 协议、默认模型，最后打印摘要并请求确认，确认后才写入。
3. **写入配置**：
   - `~/.omo/agent/models.json` → 新增/更新 `providers.<名称>`：`{ baseUrl, api, apiKey, models[] }`
   - `~/.omo/agent/settings.json` → 设置 `defaultProvider` / `defaultModel`
   - 写入前自动生成时间戳备份；与已有 provider **合并**而非覆盖。

## 非交互模式（脚本 / CI）

需要无人值守时，用参数或环境变量一次性传入，脚本将跳过向导：

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

## 配置文件位置

默认目录 `~/.omo/agent`，可用环境变量覆盖：`OMO_CODING_AGENT_DIR`（旧版：`SENPI_CODING_AGENT_DIR` / `PI_CODING_AGENT_DIR`）。

## 单独使用配置脚本

也可以不经过向导，直接用 `omo-config.mjs`：

```bash
node omo-config.mjs --base-url https://api.example.com/v1 --api-key sk-xxx --models gpt-4o
```

## License

MIT
