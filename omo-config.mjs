#!/usr/bin/env node
/**
 * omo-config.mjs - write a custom provider (baseUrl + apiKey) into OmO's
 * engine config so a single command wires up an OpenAI-compatible endpoint,
 * and optionally configure OmO's multi-agent features.
 *
 * Works on Linux / macOS / Windows with Node.js >= 18 (or Bun).
 * Shared by omo-setup.sh and omo-setup.ps1; it can also be run on its own.
 *
 * Files touched (inside the OmO agent dir):
 *   models.json    -> providers.<name> = { baseUrl, apiKey, api, models[] }
 *   settings.json  -> defaultProvider / defaultModel (unless --no-default)
 *
 * Files touched (in the OmO root, i.e. the parent of the agent dir):
 *   omo.jsonc      -> categories / agents / task / teams / memory
 *                     (only when a multi-agent flag is given)
 *
 * The agent dir is ~/.omo/agent, overridable with OMO_CODING_AGENT_DIR
 * (legacy: SENPI_CODING_AGENT_DIR / PI_CODING_AGENT_DIR). The omo.jsonc path
 * defaults to the parent of that dir and can be overridden with OMO_OMO_JSONC
 * or --omo-json.
 *
 * Multi-agent flags (all optional; omo.jsonc is only written when one is used):
 *   --category NAME=MODEL[:LEVEL]   pin a task category (repeatable)
 *   --agent NAME=MODEL[:LEVEL]      pin a curated/user agent (repeatable)
 *   --task KEY=VALUE                set a task engine key (repeatable)
 *   --memory on|off                 toggle the memory subsystem
 *   --team NAME=JSON                define a team (repeatable)
 *   --set-json JSON                 deep-merge an arbitrary object into omo.jsonc
 *   --omo-json FILE                 deep-merge a JSON/JSONC file into omo.jsonc
 *   --no-agent-config               never touch omo.jsonc
 *
 * Other flags:
 *   --lang en|zh                    message language (default: OMO_LANG, else en)
 *   --fetch-models                  print the endpoint's model list, one id per line
 *                                   (GET <baseUrl>/models; needs --base-url/--api-key)
 *   --print-models                  print the models configured for a provider
 *   --print-provider                print the provider name these inputs resolve to
 *   --models-file FILE              read "id<TAB>name" lines as the model list
 *   --recommended-warning on|off|auto
 *                                   settings.json warnings.offRecommendedModel;
 *                                   auto writes it only when no configured model is
 *                                   on OmO's recommended ladder
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const API_TYPES = new Set([
  "openai-completions",
  "openai-responses",
  "anthropic-messages",
]);

const REASONING_LEVELS = new Set([
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "auto",
]);

// Flags that may be passed more than once; parseArgs collects them into arrays.
const REPEATABLE = new Set([
  "category",
  "agent",
  "task",
  "team",
  "set-json",
  "preset",
]);

const SCHEMA_URL =
  "https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/omo.schema.json";

// The Recommended ladder, in the maintainers' order of preference. Sources:
// docs/guide/agent-model-matching.md in code-yeongyu/oh-my-openagent.
const LADDER = [
  "claude-opus-5-5",
  "claude-fable-5-1",
  "kimi-k3",
  "gpt-6-astra",
  "gpt-6.1-sol",
  "gpt-6-sol",
  "glm-5.3",
];

// The runtime's recommended-model ladder (mirrors
// dist/core/extensions/builtin/recommended-models/index.js in senpi). The
// session-start notice fires when the initial model's id is not on this
// ladder, and settings.warnings.offRecommendedModel silences it. The provider
// lanes below only matter for the runtime's auto-switch preference (which
// model it would rather use), so the ladder stays provider-independent here.
const RECOMMENDED_LADDER = [
  "claude-opus-5-5",
  "claude-fable-5-1",
  "kimi-k3",
  "gpt-6-astra",
  "gpt-6.1-sol",
  "glm-5.3",
];

const MODEL_ID_SUFFIXES = ["-ultrafast", "-unlocked", "-256k", "-fast"];

// Same normalization the runtime applies before comparing model ids.
function canonicalModelId(id) {
  let canonical = String(id).toLowerCase();
  let stripped = true;
  while (stripped) {
    stripped = false;
    for (const suffix of MODEL_ID_SUFFIXES) {
      if (canonical.endsWith(suffix)) {
        canonical = canonical.slice(0, -suffix.length);
        stripped = true;
        break;
      }
    }
  }
  return canonical === "k3" ? "kimi-k3" : canonical;
}

// True when one of the given model ids is on the recommended ladder, so the
// runtime would not warn about the initial model.
function hasRecommendedModel(models) {
  return (models || []).some((id) => RECOMMENDED_LADDER.includes(canonicalModelId(id)));
}

// Official example configurations from the Agent-Model Matching guide, adapted
// as starting templates. Provider prefixes match the guide; adjust to the
// providers you are actually logged in to.
const PRESETS = {
  "claude-openai": {
    title: "Claude plus OpenAI (official Example A)",
    patch: {
      agents: {
        "plan-consultant": { model: "anthropic/claude-opus-5-5", reasoning: "high" },
        "plan-reviewer": { model: "openai/gpt-6-astra", reasoning: "xhigh" },
        explore: { model: "openai/gpt-6-luna-fast", reasoning: "low" },
        librarian: { model: "openai/gpt-6-luna-fast", reasoning: "low" },
      },
      categories: {
        "visual-engineering": { model: "anthropic/claude-fable-5-1", reasoning: "max" },
        "deep-high": { model: "openai/gpt-6-astra", reasoning: "xhigh" },
        ultrabrain: { model: "openai/gpt-6-astra", reasoning: "max" },
        "unspecified-high": { model: "anthropic/claude-opus-5-5", reasoning: "medium" },
      },
    },
  },
  "kimi-glm": {
    title: "Kimi and GLM for Claude-shaped roles (official Example B)",
    patch: {
      agents: {
        "plan-consultant": { model: "kimi-for-coding/kimi-k3" },
      },
      categories: {
        "visual-engineering": { model: "kimi-for-coding/kimi-k3", reasoning: "max" },
        "unspecified-high": {
          models: [
            { model: "zai-coding-plan/glm-5.3", reasoning: "max" },
            "kimi-for-coding/kimi-k3",
          ],
        },
      },
    },
  },
  "deepseek-alternative": {
    title: "DeepSeek as a GPT alternative in a chain (official Example C)",
    patch: {
      categories: {
        "deep-low": {
          models: [
            { model: "openai/gpt-6-sol", reasoning: "medium" },
            { model: "deepseek/deepseek-v4-pro", reasoning: "max" },
          ],
        },
      },
    },
  },
};

const ADVICE = `OmO multi-agent recommendations (from the official Agent-Model Matching guide)
https://github.com/code-yeongyu/oh-my-openagent/blob/dev/docs/guide/agent-model-matching.md

Most people can skip all of this: OmO Native already picks a model for every
category and curated agent from its own chain against the providers you have
connected. Only override when you want to change a default.

1. Recommended main-agent ladder (maintainers' order of preference)
   Claude Opus 5.5 -> Claude Fable 5.1 -> Kimi K3 -> GPT-6 Astra
   -> GPT-6.1 Sol -> GPT-6 Sol -> GLM 5.3
   A model outside this ladder is not supported as the main agent; it may look
   fine for a few turns, then fall apart. Set it with model_profile, not here.

2. Match the family to the role
   - Claude-family: the main agent and plan-consultant (communicative roles).
   - GPT-family: plan-reviewer, ultrabrain, deep-low, deep-high.
   - Kimi K3 / GLM 5.3: Claude-shaped roles, lower on the ladder (thinly validated).
   - Small/fast models: explore, librarian, quick (search needs speed, not depth).

3. Safe overrides (same family and role shape)
   - plan-consultant: any Claude-family model, Kimi K3, GLM 5.2/5.3
   - plan-reviewer: GPT-6 Astra (xhigh/high), Claude Opus 5.5 (max) as fallback
   - visual-engineering, artistry: Claude Fable 5.1 / Opus 5.5 / Kimi K3
   - writing: Claude Opus 5.5 or Claude Opus 4.6

4. Risky (family or role mismatch) - the installer warns on these
   - ultrabrain, deep-low, deep-high on Claude or Kimi (built for GPT)
   - plan-reviewer on a small/fast model (it rubber-stamps)
   - explore or librarian on Opus/Fable (massive cost waste)
   - visual-engineering on utility or search models

5. Where to spend one scarce premium model
   Prefer low-frequency, high-leverage roles: plan-consultant (once per plan)
   and plan-reviewer (once per round). Avoid the high-volume execution slots:
   the category worker, explore and librarian.

Start from an official example with --preset claude-openai | kimi-glm |
 deepseek-alternative, then adjust the provider prefixes to your own setup.`;

// Family detection by model id substring, most specific first.
function detectFamily(model) {
  const m = String(model).toLowerCase();
  if (m.includes("fable")) return "claude";
  if (m.includes("claude") || m.includes("opus") || m.includes("sonnet") || m.includes("haiku")) return "claude";
  if (m.includes("gpt") || m.includes("o1") || m.includes("o3")) return "gpt";
  if (m.includes("kimi") || m.includes("moonshot")) return "kimi";
  if (m.includes("glm") || m.includes("zai")) return "glm";
  if (m.includes("deepseek")) return "deepseek";
  if (m.includes("grok")) return "grok";
  if (m.includes("qwen")) return "qwen";
  if (m.includes("mimo") || m.includes("xiaomi")) return "mimo";
  if (m.includes("gemini")) return "gemini";
  return "unknown";
}

function isSmallOrFast(model) {
  return /(haiku|luna|nano|flash|mini|fast|small|highspeed)/i.test(String(model));
}

function isOpusOrFable(model) {
  return /(opus|fable)/i.test(String(model));
}

function modelOf(entry) {
  if (typeof entry === "string") return entry;
  if (entry && typeof entry === "object") {
    if (typeof entry.model === "string") return entry.model;
    if (Array.isArray(entry.models) && entry.models.length) return modelOf(entry.models[0]);
  }
  return "";
}

// Apply the official safe/risky rules to the pins the user just set.
function checkRisks(patch) {
  const warnings = [];
  const GPT_ONLY = new Set(["ultrabrain", "deep-low", "deep-high"]);

  for (const [name, cfg] of Object.entries(patch.categories || {})) {
    const model = modelOf(cfg);
    const family = detectFamily(model);
    if (GPT_ONLY.has(name) && (family === "claude" || family === "kimi")) {
      warnings.push(
        `category "${name}" is built for GPT's autonomous style; ${model} ` +
          `(${family}) is a risky fit - other families finish eventually but don't shine.`,
      );
    }
    if (name === "visual-engineering" && !["claude", "kimi"].includes(family)) {
      warnings.push(
        `category "visual-engineering" should stay on the Fable 5.1 -> Opus 5.5 -> ` +
          `Kimi K3 chain; ${model} (${family}) is a risky fit.`,
      );
    }
    if (name === "writing" && family !== "claude") {
      warnings.push(
        `category "writing" is Claude-only upstream and has no cross-family ` +
          `fallback; ${model} (${family}) is a risky fit.`,
      );
    }
  }

  for (const [name, cfg] of Object.entries(patch.agents || {})) {
    const model = modelOf(cfg);
    const family = detectFamily(model);
    if (name === "plan-reviewer" && isSmallOrFast(model)) {
      warnings.push(
        `agent "plan-reviewer" on ${model} is risky: review needs sustained ` +
          `reasoning, and small models drift and rubber-stamp.`,
      );
    }
    if ((name === "explore" || name === "librarian") && isOpusOrFable(model)) {
      warnings.push(
        `agent "${name}" on ${model} is a cost waste: search needs speed, not ` +
          `intelligence. Prefer a small/fast model.`,
      );
    }
  }

  return warnings;
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const eq = a.indexOf("=");
    let key;
    let value;
    if (eq !== -1) {
      key = a.slice(2, eq);
      value = a.slice(eq + 1);
    } else {
      key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        value = "true";
      } else {
        value = next;
        i++;
      }
    }
    if (REPEATABLE.has(key)) {
      (out[key] ||= []).push(value);
    } else {
      out[key] = value;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Language (en / zh). The setup wizards pick the language first and pass it
// down via --lang; OMO_LANG works as the environment default.
// ---------------------------------------------------------------------------

const MESSAGES = {
  en: {
    "provider.written": "provider   : {0}",
    "models.written": "models     : {0}",
    "modelsFile.written": "models.json: {0}",
    "settingsFile.written": "settings   : {0}",
    "multiAgent.written": "multi-agent config:",
    "omoJsonc.written": "omo.jsonc  : {0}",
    "advice.line": "advice     : {0}",
    "updated": "omo config updated.",
    "dryRun.wouldUpdate": "[dry-run] would update {0}",
    "backupSuffix": " (backup: {0})",
    "defaultLabel": "default    : {0}",
    "apiLabel": "api        : {0}",
    "baseUrlLabel": "baseUrl    : {0}",
    "models.printed": "provider {0}: {1}",
    "models.none": "provider {0} is not configured in {1}",
    "models.empty": "provider {0} has no models configured",
    "err.fetchModelsNeedsProvider": "--fetch-models needs --base-url (and --api-key unless the endpoint is open)",
    "err.modelsFileNeedsProvider": "--models-file needs --base-url to derive the provider name (or pass --provider)",
    "err.noProvider": "no provider: pass --base-url/--api-key/--models, or --print-models with a provider",
    "err.unknownLang": "unknown --lang \"{0}\" (use en or zh)",
    "modelsFile.read": "models-file: {0} model(s) from {1}",
    "modelsFile.missing": "--models-file not found: {0}",
    "modelsFile.empty": "--models-file has no usable model ids: {0}",
  },
  zh: {
    "provider.written": "provider   ：{0}",
    "models.written": "models     ：{0}",
    "modelsFile.written": "models.json：{0}",
    "settingsFile.written": "settings   ：{0}",
    "multiAgent.written": "多智能体配置：",
    "omoJsonc.written": "omo.jsonc  ：{0}",
    "advice.line": "建议       ：{0}",
    "updated": "omo 配置已更新。",
    "dryRun.wouldUpdate": "[dry-run] 将更新 {0}",
    "backupSuffix": "（备份：{0}）",
    "defaultLabel": "默认模型   ：{0}",
    "apiLabel": "协议       ：{0}",
    "baseUrlLabel": "baseUrl    ：{0}",
    "models.printed": "provider {0}：{1}",
    "models.none": "provider {0} 未在 {1} 中配置",
    "models.empty": "provider {0} 未配置任何模型",
    "err.fetchModelsNeedsProvider": "--fetch-models 需要 --base-url（如端点不公开还需 --api-key）",
    "err.modelsFileNeedsProvider": "--models-file 需要 --base-url 以推导 provider 名称（或直接传 --provider）",
    "err.noProvider": "没有 provider：请传 --base-url/--api-key/--models，或用 --print-models 指定 provider",
    "err.unknownLang": "未知 --lang \"{0}\"（可用 en 或 zh）",
    "modelsFile.read": "models-file：从 {1} 读取到 {0} 个模型",
    "modelsFile.missing": "--models-file 不存在：{0}",
    "modelsFile.empty": "--models-file 中没有可用的模型 id：{0}",
  },
};

let LANG = "en";

function setLang(value) {
  const v = String(value || "").toLowerCase();
  if (v === "zh" || v === "zh-cn" || v === "zh-hans" || v === "cn") {
    LANG = "zh";
    return;
  }
  if (v === "en" || v === "en-us") {
    LANG = "en";
    return;
  }
  throw new Error(MESSAGES.en["err.unknownLang"].replace("{0}", value));
}

function t(key, ...args) {
  const table = MESSAGES[LANG] || MESSAGES.en;
  const template = table[key] !== undefined ? table[key] : MESSAGES.en[key];
  if (template === undefined) return key;
  return template.replace(/\{(\d+)\}/g, (m, i) => {
    const v = args[Number(i)];
    return v === undefined || v === null ? "" : String(v);
  });
}

// ---------------------------------------------------------------------------
// Model listing helpers
// ---------------------------------------------------------------------------

// Never print credentials that may sit in the base URL (userinfo or query).
function displayUrl(url) {
  const query = [...url.searchParams.keys()]
    .map((name) => `${encodeURIComponent(name)}=<redacted>`)
    .join("&");
  return `${url.origin}${url.pathname}${query ? `?${query}` : ""}`;
}

const FETCH_TIMEOUT_MS = 20000;

function fetchFailure(url, err) {
  if (err && (err.name === "AbortError" || err.name === "TimeoutError")) {
    return new Error(`GET ${displayUrl(url)} timed out after ${FETCH_TIMEOUT_MS / 1000}s`);
  }
  return new Error(`GET ${displayUrl(url)} failed: ${err && err.message ? err.message : err}`);
}

// GET <baseUrl>/models (the same URL senpi's model discovery uses). Returns
// [{ id, name }]; auth is optional so open endpoints work too. The abort timer
// covers the body read as well as the request, so a server that answers with
// headers and then stalls cannot hang the wizard.
async function fetchModelList(baseUrl, apiKey) {
  const url = new URL(String(baseUrl).trim());
  url.pathname = `${url.pathname.replace(/\/+$/u, "")}/models`;
  const headers = { accept: "application/json" };
  if (apiKey) headers.authorization = `Bearer ${apiKey}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(url, { headers, signal: controller.signal });
  } catch (err) {
    clearTimeout(timer);
    throw fetchFailure(url, err);
  }
  if (!response.ok) {
    clearTimeout(timer);
    throw new Error(`GET ${displayUrl(url)} failed: HTTP ${response.status}`);
  }
  let payload;
  try {
    payload = await response.json();
  } catch (err) {
    clearTimeout(timer);
    if (err && (err.name === "AbortError" || err.name === "TimeoutError")) {
      throw fetchFailure(url, err);
    }
    throw new Error(`GET ${displayUrl(url)} did not return JSON`);
  }
  clearTimeout(timer);
  const data = Array.isArray(payload)
    ? payload
    : payload && Array.isArray(payload.data)
      ? payload.data
      : undefined;
  if (!Array.isArray(data)) {
    throw new Error(`GET ${displayUrl(url)} did not return a model list`);
  }
  const seen = new Set();
  const out = [];
  for (const entry of data) {
    if (!entry || typeof entry !== "object" || typeof entry.id !== "string") continue;
    const id = entry.id.trim();
    if (!id || seen.has(id)) continue;
    seen.add(id);
    const name = typeof entry.name === "string" && entry.name.trim() ? entry.name.trim() : id;
    out.push({ id, name });
  }
  return out;
}

// "id<TAB>name" per line; blank lines and # comments are ignored.
function readModelsFile(file) {
  const resolved = path.resolve(String(file).replace(/^~(?=$|\/)/, os.homedir()));
  if (!fs.existsSync(resolved)) {
    throw new Error(t("modelsFile.missing", resolved));
  }
  const out = [];
  const seen = new Set();
  for (const line of fs.readFileSync(resolved, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const tab = trimmed.indexOf("\t");
    const id = (tab === -1 ? trimmed : trimmed.slice(0, tab)).trim();
    const name = tab === -1 ? id : trimmed.slice(tab + 1).trim() || id;
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push({ id, name });
  }
  if (!out.length) throw new Error(t("modelsFile.empty", resolved));
  return out;
}

function firstDefined(...vals) {
  for (const v of vals) {
    if (v !== undefined && v !== null && v !== "") return v;
  }
  return undefined;
}

function agentDir() {
  const override = firstDefined(
    process.env.OMO_CODING_AGENT_DIR,
    process.env.SENPI_CODING_AGENT_DIR,
    process.env.PI_CODING_AGENT_DIR,
  );
  if (override) return path.resolve(override.replace(/^~(?=$|\/)/, os.homedir()));
  return path.join(os.homedir(), ".omo", "agent");
}

// omo.jsonc sits in the OmO root: the parent of the agent dir, unless the
// caller points us somewhere else explicitly.
function omoJsoncPath(explicit) {
  if (explicit) {
    return path.resolve(
      String(explicit).replace(/^~(?=$|\/)/, os.homedir()),
    );
  }
  const envOverride = firstDefined(process.env.OMO_OMO_JSONC);
  if (envOverride) {
    return path.resolve(envOverride.replace(/^~(?=$|\/)/, os.homedir()));
  }
  return path.join(path.dirname(agentDir()), "omo.jsonc");
}

function timestamp() {
  return new Date().toISOString().replace(/[:.]/g, "-").replace(/-?Z$/, "Z");
}

function backup(file) {
  if (!fs.existsSync(file)) return null;
  const dest = `${file}.bak.${timestamp()}`;
  fs.copyFileSync(file, dest);
  return dest;
}

function readJson(file, fallback) {
  if (!fs.existsSync(file)) return fallback;
  const raw = fs.readFileSync(file, "utf8").trim();
  if (raw === "") return fallback;
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`cannot parse ${file}: ${err.message}`);
  }
}

// JSONC reader: strips // and /* */ comments and trailing commas, then parses.
// String-aware, so a `//` or `,}` inside a string value is left alone.
function parseJsonc(raw, file) {
  let out = "";
  let i = 0;
  const n = raw.length;
  let inStr = false;
  while (i < n) {
    const c = raw[i];
    if (inStr) {
      out += c;
      if (c === "\\") {
        out += raw[i + 1] ?? "";
        i += 2;
        continue;
      }
      if (c === '"') inStr = false;
      i++;
      continue;
    }
    if (c === '"') {
      inStr = true;
      out += c;
      i++;
      continue;
    }
    if (c === "/" && raw[i + 1] === "/") {
      while (i < n && raw[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && raw[i + 1] === "*") {
      i += 2;
      while (i < n && !(raw[i] === "*" && raw[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    if (c === ",") {
      // Trailing comma: drop it when only whitespace/comments precede a closer.
      let j = i + 1;
      for (;;) {
        while (j < n && /\s/.test(raw[j])) j++;
        if (raw[j] === "/" && raw[j + 1] === "/") {
          while (j < n && raw[j] !== "\n") j++;
          continue;
        }
        if (raw[j] === "/" && raw[j + 1] === "*") {
          j += 2;
          while (j < n && !(raw[j] === "*" && raw[j + 1] === "/")) j++;
          j += 2;
          continue;
        }
        break;
      }
      if (raw[j] === "}" || raw[j] === "]") {
        i++;
        continue;
      }
    }
    out += c;
    i++;
  }
  try {
    return JSON.parse(out);
  } catch (err) {
    throw new Error(`cannot parse ${file}: ${err.message}`);
  }
}

function readJsonc(file, fallback) {
  if (!fs.existsSync(file)) return fallback;
  const raw = fs.readFileSync(file, "utf8");
  if (raw.trim() === "") return fallback;
  return parseJsonc(raw, file);
}

function isPlainObject(v) {
  return (
    v !== null && typeof v === "object" && !Array.isArray(v) &&
    Object.getPrototypeOf(v) === Object.prototype
  );
}

// Deep merge: plain objects merge recursively; arrays and scalars replace.
// __proto__ / prototype / constructor are dropped (prototype-pollution guard).
function deepMerge(target, patch) {
  if (!isPlainObject(patch)) return patch;
  const out = isPlainObject(target) ? { ...target } : {};
  for (const [k, v] of Object.entries(patch)) {
    if (k === "__proto__" || k === "prototype" || k === "constructor") continue;
    out[k] = isPlainObject(v) && isPlainObject(out[k])
      ? deepMerge(out[k], v)
      : v;
  }
  return out;
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n", "utf8");
}

function normalizeBaseUrl(url) {
  return url.replace(/\/+$/, "");
}

function deriveProviderName(baseUrl) {
  let host;
  try {
    host = new URL(baseUrl).hostname;
  } catch {
    host = baseUrl.replace(/^https?:\/\//, "").split("/")[0];
  }
  const parts = host.split(".").filter(Boolean);
  const stripped = parts.filter(
    (p) => !["www", "api", "llm", "ai", "gateway", "gw"].includes(p.toLowerCase()),
  );
  const chosen = (stripped.length >= 2 ? stripped : parts).slice(-2);
  return chosen.join("-").replace(/[^a-z0-9-]/gi, "-").toLowerCase();
}

function normalizeApiType(value) {
  if (!value) return "openai-completions";
  const v = value.toLowerCase();
  const aliases = {
    openai: "openai-completions",
    "openai-chat": "openai-completions",
    chat: "openai-completions",
    completions: "openai-completions",
    responses: "openai-responses",
    anthropic: "anthropic-messages",
  };
  const resolved = aliases[v] || v;
  if (!API_TYPES.has(resolved)) {
    throw new Error(
      `invalid --api-type "${value}" (use: ${[...API_TYPES].join(", ")})`,
    );
  }
  return resolved;
}

function parseModels(value) {
  return String(value)
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

// "provider/model:level" -> { model, reasoning } when the tail is a level.
function parseModelSpec(spec, label) {
  const raw = String(spec).trim();
  if (!raw) throw new Error(`${label}: empty value`);
  const colon = raw.lastIndexOf(":");
  if (colon > 0) {
    const tail = raw.slice(colon + 1).toLowerCase();
    if (REASONING_LEVELS.has(tail)) {
      return { model: raw.slice(0, colon), reasoning: tail };
    }
  }
  return { model: raw };
}

function entryFor(spec, label) {
  const { model, reasoning } = parseModelSpec(spec, label);
  const entry = { model };
  if (reasoning) entry.reasoning = reasoning;
  return entry;
}

// NAME=MODEL[:LEVEL] -> { NAME: { model, reasoning? } }
function parsePins(list, flag) {
  const out = {};
  for (const item of list || []) {
    const eq = String(item).indexOf("=");
    if (eq <= 0) {
      throw new Error(`invalid ${flag} "${item}" (expected NAME=MODEL[:LEVEL])`);
    }
    const name = String(item).slice(0, eq).trim();
    const spec = String(item).slice(eq + 1);
    if (!name) throw new Error(`invalid ${flag} "${item}" (empty name)`);
    out[name] = entryFor(spec, `${flag} ${name}`);
  }
  return out;
}

// KEY=VALUE -> { KEY: parsedValue }, where VALUE is JSON when it parses.
function parseTaskSettings(list) {
  const out = {};
  for (const item of list || []) {
    const eq = String(item).indexOf("=");
    if (eq <= 0) {
      throw new Error(`invalid --task "${item}" (expected KEY=VALUE)`);
    }
    const key = String(item).slice(0, eq).trim();
    const rawValue = String(item).slice(eq + 1).trim();
    let value = rawValue;
    try {
      value = JSON.parse(rawValue);
    } catch {
      value = rawValue; // bare word: keep as a string
    }
    out[key] = value;
  }
  return out;
}

// NAME=JSON -> { NAME: parsedObject }
function parseTeams(list) {
  const out = {};
  for (const item of list || []) {
    const eq = String(item).indexOf("=");
    if (eq <= 0) {
      throw new Error(`invalid --team "${item}" (expected NAME=JSON)`);
    }
    const name = String(item).slice(0, eq).trim();
    const rawJson = String(item).slice(eq + 1);
    let value;
    try {
      value = JSON.parse(rawJson);
    } catch (err) {
      throw new Error(`invalid --team ${name} JSON: ${err.message}`);
    }
    if (!isPlainObject(value)) {
      throw new Error(`invalid --team ${name}: value must be a JSON object`);
    }
    out[name] = value;
  }
  return out;
}

// Merge two omo.jsonc patches. Record sections (categories/agents/teams) merge
// at key level so a later entry replaces an earlier one wholesale; other
// objects (task, memory, arbitrary keys) deep-merge.
function mergePatch(base, extra) {
  const out = { ...base };
  for (const [k, v] of Object.entries(extra)) {
    if (k === "__proto__" || k === "prototype" || k === "constructor") continue;
    if (["categories", "agents", "teams"].includes(k) && isPlainObject(v)) {
      out[k] = { ...(isPlainObject(out[k]) ? out[k] : {}), ...v };
    } else {
      out[k] = deepMerge(out[k], v);
    }
  }
  return out;
}

// Build the omo.jsonc patch from the multi-agent flags. Returns null when no
// multi-agent flag was given, so omo.jsonc is left untouched.
function buildAgentPatch(args) {
  let patch = {};

  for (const name of args.preset || []) {
    const preset = PRESETS[name];
    if (!preset) {
      throw new Error(
        `unknown --preset "${name}" (use: ${Object.keys(PRESETS).join(", ")})`,
      );
    }
    patch = mergePatch(patch, preset.patch);
  }

  const categories = parsePins(args.category, "--category");
  if (Object.keys(categories).length) {
    patch.categories = { ...(patch.categories || {}), ...categories };
  }

  const agents = parsePins(args.agent, "--agent");
  if (Object.keys(agents).length) {
    patch.agents = { ...(patch.agents || {}), ...agents };
  }

  const task = parseTaskSettings(args.task);
  if (Object.keys(task).length) {
    patch.task = deepMerge(patch.task || {}, task);
  }

  if (args.memory !== undefined) {
    const on = String(args.memory).toLowerCase();
    if (!["on", "off", "true", "false", "yes", "no", "1", "0"].includes(on)) {
      throw new Error(`invalid --memory "${args.memory}" (use on or off)`);
    }
    patch.memory = deepMerge(patch.memory || {}, { enabled: ["on", "true", "yes", "1"].includes(on) });
  }

  const teams = parseTeams(args.team);
  if (Object.keys(teams).length) {
    patch.teams = { ...(patch.teams || {}), ...teams };
  }

  for (const raw of args["set-json"] || []) {
    let value;
    try {
      value = JSON.parse(raw);
    } catch (err) {
      throw new Error(`invalid --set-json: ${err.message}`);
    }
    if (!isPlainObject(value)) {
      throw new Error("invalid --set-json: value must be a JSON object");
    }
    Object.assign(patch, mergePatch(patch, value));
  }

  if (args["omo-json"] !== undefined) {
    const file = path.resolve(
      String(args["omo-json"]).replace(/^~(?=$|\/)/, os.homedir()),
    );
    if (!fs.existsSync(file)) {
      throw new Error(`--omo-json file not found: ${file}`);
    }
    const value = parseJsonc(fs.readFileSync(file, "utf8"), file);
    if (!isPlainObject(value)) {
      throw new Error(`--omo-json file must contain a JSON object: ${file}`);
    }
    Object.assign(patch, mergePatch(patch, value));
  }

  return Object.keys(patch).length ? patch : null;
}

function summarizeAgentPatch(patch) {
  const lines = [];
  // A pin may be a single `model` or a `models` chain; show whichever is set.
  const describe = (cfg) => {
    if (typeof cfg.model === "string") {
      return cfg.model + (cfg.reasoning ? `:${cfg.reasoning}` : "");
    }
    if (Array.isArray(cfg.models) && cfg.models.length) {
      const first = cfg.models[0];
      const head = typeof first === "string"
        ? first
        : `${first.model}${first.reasoning ? `:${first.reasoning}` : ""}`;
      return cfg.models.length > 1 ? `${head} (+${cfg.models.length - 1})` : head;
    }
    return "(unset)";
  };
  for (const [name, cfg] of Object.entries(patch.categories || {})) {
    lines.push(`category   : ${name} = ${describe(cfg)}`);
  }
  for (const [name, cfg] of Object.entries(patch.agents || {})) {
    lines.push(`agent      : ${name} = ${describe(cfg)}`);
  }
  for (const [key, value] of Object.entries(patch.task || {})) {
    lines.push(`task       : ${key} = ${JSON.stringify(value)}`);
  }
  if (patch.memory) {
    lines.push(`memory     : ${patch.memory.enabled ? "enabled" : "disabled"}`);
  }
  for (const name of Object.keys(patch.teams || {})) {
    lines.push(`team       : ${name}`);
  }
  return lines;
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  setLang(firstDefined(args.lang, process.env.OMO_LANG) || "en");

  const baseUrl = normalizeBaseUrl(
    firstDefined(args["base-url"], args.baseUrl, process.env.OMO_BASE_URL) || "",
  );
  const apiKey = firstDefined(
    args["api-key"],
    args.apiKey,
    process.env.OMO_API_KEY,
  );
  const apiType = normalizeApiType(
    firstDefined(args["api-type"], process.env.OMO_API_TYPE),
  );
  const dryRun = args["dry-run"] === "true";
  const noDefault = args["no-default"] === "true";
  const noAgentConfig = args["no-agent-config"] === "true";
  const recommendedWarning = String(
    firstDefined(args["recommended-warning"], "auto"),
  ).toLowerCase();
  if (!["on", "off", "auto"].includes(recommendedWarning)) {
    throw new Error(`invalid --recommended-warning "${args["recommended-warning"]}" (use on, off or auto)`);
  }

  // Model entries carry ids and display names; --models-file wins over --models
  // so a wizard can hand over a fetched, user-curated list.
  let modelEntries;
  if (args["models-file"] !== undefined) {
    modelEntries = readModelsFile(args["models-file"]);
    console.error(t("modelsFile.read", modelEntries.length, args["models-file"]));
  } else {
    modelEntries = parseModels(
      firstDefined(args.models, process.env.OMO_MODELS) || "",
    ).map((id) => ({ id, name: id }));
  }
  const models = modelEntries.map((m) => m.id);

  if (args.advice === "true") {
    console.log(ADVICE);
    console.log("");
    if (!Object.keys(PRESETS).length) return;
    console.log("Available presets: " + Object.keys(PRESETS).join(", "));
    return;
  }

  // --fetch-models: print the endpoint's listing as "id<TAB>name" lines.
  if (args["fetch-models"] === "true") {
    if (!baseUrl) throw new Error(t("err.fetchModelsNeedsProvider"));
    return fetchModelList(baseUrl, apiKey).then((list) => {
      for (const m of list) console.log(`${m.id}\t${m.name}`);
    });
  }

  const agentPatch = noAgentConfig ? null : buildAgentPatch(args);
  const wantsProvider = Boolean(baseUrl || apiKey || models.length);

  const providerName =
    firstDefined(args.provider, process.env.OMO_PROVIDER) ||
    (wantsProvider || args["models-file"] !== undefined
      ? (baseUrl ? deriveProviderName(baseUrl) : undefined)
      : undefined);

  // --print-provider: echo the resolved provider id (wizard helper).
  if (args["print-provider"] === "true") {
    if (!providerName) throw new Error(t("err.noProvider"));
    console.log(providerName);
    return;
  }

  // --print-models: echo the provider's configured models as "id<TAB>name".
  if (args["print-models"] === "true") {
    if (!providerName) throw new Error(t("err.noProvider"));
    const file = path.join(agentDir(), "models.json");
    const doc = readJson(file, { providers: {} });
    const provider = doc && doc.providers ? doc.providers[providerName] : undefined;
    if (!provider) throw new Error(t("models.none", providerName, file));
    const list = Array.isArray(provider.models) ? provider.models : [];
    if (!list.length) throw new Error(t("models.empty", providerName));
    for (const entry of list) {
      if (typeof entry === "string") console.log(`${entry}\t${entry}`);
      else if (entry && typeof entry.id === "string") {
        const name = typeof entry.name === "string" && entry.name ? entry.name : entry.id;
        console.log(`${entry.id}\t${name}`);
      }
    }
    return;
  }

  if (wantsProvider) {
    if (!baseUrl) throw new Error("missing --base-url (or OMO_BASE_URL)");
    if (!apiKey) throw new Error("missing --api-key (or OMO_API_KEY)");
    if (models.length === 0) {
      throw new Error("missing --models (comma-separated model ids, or OMO_MODELS)");
    }
  } else if (!agentPatch) {
    throw new Error(
      "nothing to do: pass provider flags (--base-url/--api-key/--models) " +
        "or a multi-agent flag (--category/--agent/--task/--memory/--team/--set-json)",
    );
  }

  if (providerName && !/^[a-zA-Z0-9._-]+$/.test(providerName)) {
    throw new Error(`invalid --provider "${providerName}"`);
  }

  const dir = agentDir();
  const modelsFile = path.join(dir, "models.json");
  const settingsFile = path.join(dir, "settings.json");
  const omoJsonc = agentPatch ? omoJsoncPath() : null;

  // Prefer a model the runtime recognizes as recommended when the user did not
  // pick a default explicitly; that is what keeps the session-start warning away.
  const ladderHit = (models || []).find((id) =>
    RECOMMENDED_LADDER.includes(canonicalModelId(id)),
  );
  const defaultModel = firstDefined(
    args["default-model"],
    process.env.OMO_DEFAULT_MODEL,
    ladderHit ? `${providerName}/${ladderHit}` : undefined,
    `${providerName}/${models[0]}`,
  );

  // settings.warnings.offRecommendedModel silences the runtime's
  // "Non-recommended model" notice. auto = silence it only when none of the
  // configured models is on the recommended ladder for this provider.
  let offRecommendedModel = null;
  if (wantsProvider && recommendedWarning !== "on") {
    if (recommendedWarning === "off") offRecommendedModel = true;
    else if (recommendedWarning === "auto") {
      offRecommendedModel = !hasRecommendedModel(models);
    }
  }

  const providerBlock = {
    baseUrl,
    api: apiType,
    apiKey,
    models: modelEntries.map((m) => ({ id: m.id, name: m.name })),
  };

  const plan = {
    agentDir: dir,
    provider: providerName,
    baseUrl,
    api: apiType,
    models,
    defaultProvider: providerName,
    defaultModel,
    ...(offRecommendedModel !== null ? { offRecommendedModel } : {}),
    ...(agentPatch ? { omoJsonc, multiAgent: agentPatch } : {}),
  };

  const risks = agentPatch && args["no-advice"] !== "true" ? checkRisks(agentPatch) : [];

  if (dryRun) {
    if (wantsProvider) {
      console.log(t("dryRun.wouldUpdate", modelsFile));
      if (!noDefault) console.log(t("dryRun.wouldUpdate", settingsFile));
    }
    if (agentPatch) console.log(t("dryRun.wouldUpdate", omoJsonc));
    for (const w of risks) console.log(`[advice] ${w}`);
    console.log(JSON.stringify(plan, null, 2));
    return;
  }

  if (wantsProvider) {
    const modelsJson = readJson(modelsFile, { providers: {} });
    if (!modelsJson.providers || typeof modelsJson.providers !== "object") {
      modelsJson.providers = {};
    }
    const modelsBackup = backup(modelsFile);
    modelsJson.providers[providerName] = providerBlock;
    writeJson(modelsFile, modelsJson);

    let settingsBackup = null;
    if (!noDefault || offRecommendedModel !== null) {
      const settings = readJson(settingsFile, {});
      settingsBackup = backup(settingsFile);
      if (!noDefault) {
        settings.defaultProvider = providerName;
        settings.defaultModel = defaultModel;
      }
      if (offRecommendedModel !== null) {
        settings.warnings = { ...(settings.warnings || {}), offRecommendedModel };
      }
      writeJson(settingsFile, settings);
    }

    console.log(t("provider.written", providerName));
    console.log(t("baseUrlLabel", baseUrl));
    console.log(t("apiLabel", apiType));
    console.log(t("models.written", models.join(", ")));
    console.log(
      t(
        "modelsFile.written",
        modelsFile + (modelsBackup ? t("backupSuffix", path.basename(modelsBackup)) : ""),
      ),
    );
    if (!noDefault) {
      console.log(t("defaultLabel", defaultModel));
    }
    if (settingsBackup) {
      console.log(
        t("settingsFile.written", settingsFile + t("backupSuffix", path.basename(settingsBackup))),
      );
    }
  }

  if (agentPatch) {
    const existing = readJsonc(omoJsonc, {});
    if (!isPlainObject(existing)) {
      throw new Error(`existing ${omoJsonc} is not a JSON object; refusing to overwrite`);
    }
    const merged = deepMerge(existing, agentPatch);
    if (!merged.$schema) merged.$schema = SCHEMA_URL;
    const backupPath = backup(omoJsonc);
    writeJson(omoJsonc, merged);
    console.log("");
    console.log(t("multiAgent.written"));
    for (const line of summarizeAgentPatch(agentPatch)) console.log(line);
    console.log(
      t("omoJsonc.written", omoJsonc + (backupPath ? t("backupSuffix", path.basename(backupPath)) : "")),
    );
    for (const w of risks) console.log(t("advice.line", w));
  }

  console.log(t("updated"));
}

Promise.resolve()
  .then(main)
  .catch((err) => {
    console.error("omo-config: " + (err && err.message ? err.message : err));
    process.exit(1);
  });
