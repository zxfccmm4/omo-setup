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
]);

const SCHEMA_URL =
  "https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/omo.schema.json";

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

// Build the omo.jsonc patch from the multi-agent flags. Returns null when no
// multi-agent flag was given, so omo.jsonc is left untouched.
function buildAgentPatch(args) {
  const patch = {};

  const categories = parsePins(args.category, "--category");
  if (Object.keys(categories).length) patch.categories = categories;

  const agents = parsePins(args.agent, "--agent");
  if (Object.keys(agents).length) patch.agents = agents;

  const task = parseTaskSettings(args.task);
  if (Object.keys(task).length) patch.task = task;

  if (args.memory !== undefined) {
    const on = String(args.memory).toLowerCase();
    if (!["on", "off", "true", "false", "yes", "no", "1", "0"].includes(on)) {
      throw new Error(`invalid --memory "${args.memory}" (use on or off)`);
    }
    patch.memory = { enabled: ["on", "true", "yes", "1"].includes(on) };
  }

  const teams = parseTeams(args.team);
  if (Object.keys(teams).length) patch.teams = teams;

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
    Object.assign(patch, deepMerge(patch, value));
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
    Object.assign(patch, deepMerge(patch, value));
  }

  return Object.keys(patch).length ? patch : null;
}

function summarizeAgentPatch(patch) {
  const lines = [];
  for (const [name, cfg] of Object.entries(patch.categories || {})) {
    lines.push(`category   : ${name} = ${cfg.model}${cfg.reasoning ? `:${cfg.reasoning}` : ""}`);
  }
  for (const [name, cfg] of Object.entries(patch.agents || {})) {
    lines.push(`agent      : ${name} = ${cfg.model}${cfg.reasoning ? `:${cfg.reasoning}` : ""}`);
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
  const models = parseModels(
    firstDefined(args.models, process.env.OMO_MODELS) || "",
  );
  const dryRun = args["dry-run"] === "true";
  const noDefault = args["no-default"] === "true";
  const noAgentConfig = args["no-agent-config"] === "true";

  const agentPatch = noAgentConfig ? null : buildAgentPatch(args);
  const wantsProvider = Boolean(baseUrl || apiKey || models.length);

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

  const providerName =
    firstDefined(args.provider, process.env.OMO_PROVIDER) ||
    (wantsProvider ? deriveProviderName(baseUrl) : undefined);
  if (providerName && !/^[a-zA-Z0-9._-]+$/.test(providerName)) {
    throw new Error(`invalid --provider "${providerName}"`);
  }

  const dir = agentDir();
  const modelsFile = path.join(dir, "models.json");
  const settingsFile = path.join(dir, "settings.json");
  const omoJsonc = agentPatch ? omoJsoncPath() : null;

  const defaultModel = firstDefined(
    args["default-model"],
    process.env.OMO_DEFAULT_MODEL,
    `${providerName}/${models[0]}`,
  );

  const providerBlock = {
    baseUrl,
    api: apiType,
    apiKey,
    models: models.map((id) => ({ id, name: id })),
  };

  const plan = {
    agentDir: dir,
    provider: providerName,
    baseUrl,
    api: apiType,
    models,
    defaultProvider: providerName,
    defaultModel,
    ...(agentPatch ? { omoJsonc, multiAgent: agentPatch } : {}),
  };

  if (dryRun) {
    if (wantsProvider) {
      console.log("[dry-run] would update " + modelsFile);
      if (!noDefault) console.log("[dry-run] would update " + settingsFile);
    }
    if (agentPatch) console.log("[dry-run] would update " + omoJsonc);
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
    if (!noDefault) {
      const settings = readJson(settingsFile, {});
      settingsBackup = backup(settingsFile);
      settings.defaultProvider = providerName;
      settings.defaultModel = defaultModel;
      writeJson(settingsFile, settings);
    }

    console.log(`provider   : ${providerName}`);
    console.log(`baseUrl    : ${baseUrl}`);
    console.log(`api        : ${apiType}`);
    console.log(`models     : ${models.join(", ")}`);
    console.log(`models.json: ${modelsFile}${modelsBackup ? ` (backup: ${path.basename(modelsBackup)})` : ""}`);
    if (!noDefault) {
      console.log(`default    : ${defaultModel}`);
      console.log(`settings   : ${settingsFile}${settingsBackup ? ` (backup: ${path.basename(settingsBackup)})` : ""}`);
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
    console.log("multi-agent config:");
    for (const line of summarizeAgentPatch(agentPatch)) console.log(line);
    console.log(`omo.jsonc  : ${omoJsonc}${backupPath ? ` (backup: ${path.basename(backupPath)})` : ""}`);
  }

  console.log("omo config updated.");
}

try {
  main();
} catch (err) {
  console.error("omo-config: " + (err && err.message ? err.message : err));
  process.exit(1);
}
