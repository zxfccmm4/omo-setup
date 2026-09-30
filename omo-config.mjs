#!/usr/bin/env node
/**
 * omo-config.mjs - write a custom provider (baseUrl + apiKey) into OmO's
 * engine config so a single command wires up an OpenAI-compatible endpoint.
 *
 * Works on Linux / macOS / Windows with Node.js >= 18 (or Bun).
 * Shared by omo-setup.sh and omo-setup.ps1; it can also be run on its own.
 *
 * Files touched (inside the OmO agent dir):
 *   models.json    -> providers.<name> = { baseUrl, apiKey, api, models[] }
 *   settings.json  -> defaultProvider / defaultModel (unless --no-default)
 *
 * The agent dir is ~/.omo/agent, overridable with OMO_CODING_AGENT_DIR
 * (legacy: SENPI_CODING_AGENT_DIR / PI_CODING_AGENT_DIR).
 */

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const API_TYPES = new Set([
  "openai-completions",
  "openai-responses",
  "anthropic-messages",
]);

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const eq = a.indexOf("=");
    if (eq !== -1) {
      out[a.slice(2, eq)] = a.slice(eq + 1);
    } else {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        out[key] = "true";
      } else {
        out[key] = next;
        i++;
      }
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

  if (!baseUrl) throw new Error("missing --base-url (or OMO_BASE_URL)");
  if (!apiKey) throw new Error("missing --api-key (or OMO_API_KEY)");
  if (models.length === 0) {
    throw new Error("missing --models (comma-separated model ids, or OMO_MODELS)");
  }

  const providerName =
    firstDefined(args.provider, process.env.OMO_PROVIDER) ||
    deriveProviderName(baseUrl);
  if (!/^[a-zA-Z0-9._-]+$/.test(providerName)) {
    throw new Error(`invalid --provider "${providerName}"`);
  }

  const dir = agentDir();
  const modelsFile = path.join(dir, "models.json");
  const settingsFile = path.join(dir, "settings.json");

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
  };

  if (dryRun) {
    console.log("[dry-run] would update " + modelsFile);
    console.log("[dry-run] would update " + settingsFile);
    console.log(JSON.stringify(plan, null, 2));
    return;
  }

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
  console.log("omo config updated.");
}

try {
  main();
} catch (err) {
  console.error("omo-config: " + (err && err.message ? err.message : err));
  process.exit(1);
}
