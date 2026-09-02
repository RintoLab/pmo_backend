#!/usr/bin/env node

import { chmodSync, existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const PROVIDER = "openai-codex";

// SDK dependencies occasionally log through console. stdout belongs solely to
// the JSONL protocol, so route every diagnostic API to stderr before import.
for (const method of ["log", "info", "warn", "debug", "error"]) {
  console[method] = (...values) => {
    const rendered = values.map((value) => typeof value === "string" ? value : "[object]").join(" ");
    process.stderr.write(`${redact(rendered)}\n`);
  };
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function redact(value) {
  return String(value)
    .replace(/\b(?:eyJ|sk-)[A-Za-z0-9._~-]{12,}\b/gu, "[redacted]")
    .replace(/(access|refresh|authorization)[_-]?(token|code)\s*[:=]\s*\S+/giu, "[redacted]")
    .slice(0, 500);
}

function args(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) return {};
    result[key.slice(2)] = value;
  }
  return result;
}

function packageRoot(piExecutable) {
  let current = dirname(realpathSync(piExecutable));
  while (true) {
    const manifest = join(current, "package.json");
    if (existsSync(manifest)) {
      const parsed = JSON.parse(readFileSync(manifest, "utf8"));
      if (
        parsed &&
        typeof parsed === "object" &&
        (parsed.exports?.["."] || existsSync(join(current, "dist", "index.js")))
      ) {
        return { root: current, manifest: parsed };
      }
    }
    const parent = dirname(current);
    if (parent === current) throw new Error("pi_sdk_unavailable");
    current = parent;
  }
}

function sdkEntry(root, manifest) {
  const exported = manifest.exports?.["."];
  const relative = typeof exported === "string" ? exported : exported?.import ?? exported?.default;
  const candidate = relative ? resolve(root, relative) : join(root, "dist", "index.js");
  if (!isAbsolute(candidate) || !existsSync(candidate)) throw new Error("pi_sdk_unavailable");
  return candidate;
}

function errorCode(error) {
  if (controller.signal.aborted) return "auth_cancelled";
  if (error instanceof Error && ["invalid_arguments", "pi_sdk_unavailable"].includes(error.message)) {
    return error.message;
  }
  return "auth_failed";
}

const options = args(process.argv.slice(2));
const authPath = options["auth-path"] ? resolve(options["auth-path"]) : null;
if (authPath) process.env.PI_CODING_AGENT_DIR = dirname(authPath);

const controller = new AbortController();
const abort = () => controller.abort();
process.once("SIGTERM", abort);
process.once("SIGINT", abort);

async function main() {
  if (!options.action || !options["pi-executable"] || !authPath) {
    throw new Error("invalid_arguments");
  }

  const { root, manifest } = packageRoot(options["pi-executable"]);
  process.stderr.write(`Using Pi SDK ${redact(manifest.name)}@${redact(manifest.version)}\n`);
  const sdk = await import(pathToFileURL(sdkEntry(root, manifest)).href);
  if (typeof sdk.ModelRuntime?.create !== "function") throw new Error("pi_sdk_unavailable");

  const runtime = await sdk.ModelRuntime.create({
    authPath,
    modelsPath: null,
    allowModelNetwork: false,
    refreshOnCreate: false,
    signal: controller.signal,
  });

  if (options.action === "login") {
    await runtime.login(PROVIDER, "oauth", {
      signal: controller.signal,
      prompt: async (request) => {
        if (request.type === "select") return "device_code";
        throw new Error("unexpected_auth_prompt");
      },
      notify: (event) => {
        if (event.type !== "device_code") return;
        emit({
          type: "device_code",
          provider: PROVIDER,
          verificationUrl: event.verificationUri ?? event.verificationUrl,
          userCode: event.userCode,
          expiresInSeconds: event.expiresInSeconds ?? 900,
        });
      },
    });
  } else if (options.action === "logout") {
    await runtime.logout(PROVIDER, { signal: controller.signal });
  } else {
    throw new Error("invalid_arguments");
  }

  emit({ type: "completed", provider: PROVIDER, success: true });
}

try {
  await main();
} catch (error) {
  const code = errorCode(error);
  process.stderr.write(`Pi OAuth helper failed (${code})\n`);
  emit({
    type: "error",
    provider: PROVIDER,
    code,
    message: code === "auth_cancelled" ? "Authorization was cancelled." : "Authorization failed.",
  });
  process.exitCode = 1;
} finally {
  if (typeof authPath === "string" && existsSync(authPath)) chmodSync(authPath, 0o600);
}
