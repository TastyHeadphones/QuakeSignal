import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const requiredSecretNames = [
  "APNS_PRIVATE_KEY",
  "APNS_KEY_ID",
  "APNS_TEAM_ID",
  "APNS_BUNDLE_ID",
];

export { requiredSecretNames };

/**
 * `wrangler secret list` reads the Worker selected by the active config. The
 * production workflow intentionally uses the default config, while the
 * isolated staging workflow passes its generated config explicitly. Keeping
 * this parser small and strict prevents a typo from silently checking the
 * production Worker during staging validation.
 */
export function parseConfigArgument(argv) {
  if (argv.length === 0) return undefined;
  if (argv.length === 2 && argv[0] === "--config" && argv[1].trim()) {
    return argv[1];
  }

  throw new Error("Usage: node scripts/verify-apns-worker-secrets.mjs [--config <path>]");
}

export function listedSecretNames(rawOutput) {
  const listedSecrets = JSON.parse(rawOutput);
  if (!Array.isArray(listedSecrets)) {
    throw new Error("Wrangler returned an unexpected Worker secret-list format.");
  }

  return new Set(
    listedSecrets.flatMap((secret) =>
      secret && typeof secret === "object" && typeof secret.name === "string"
        ? [secret.name]
        : [],
    ),
  );
}

export function missingRequiredSecretNames(availableNames) {
  return requiredSecretNames.filter((name) => !availableNames.has(name));
}

export function verifyAPNSSecretNames(argv = process.argv.slice(2)) {
  const configPath = parseConfigArgument(argv);
  const wranglerArgs = ["wrangler", "secret", "list", "--format", "json"];
  if (configPath) wranglerArgs.push("--config", configPath);

  // `wrangler secret list` returns names and metadata only, never secret values.
  const result = spawnSync(
    "npx",
    wranglerArgs,
    { encoding: "utf8" },
  );

  if (result.status !== 0) {
    console.error(
      "Unable to list Worker secret names. Check Cloudflare credentials and Worker permissions.",
    );
    return result.status ?? 1;
  }

  try {
    const availableNames = listedSecretNames(result.stdout);
    const missingNames = missingRequiredSecretNames(availableNames);
    if (missingNames.length > 0) {
      console.error(
        `Cloudflare Worker is missing required APNs secret name(s): ${missingNames.join(", ")}`,
      );
      return 1;
    }

    console.log("Required APNs Worker secret names are present.");
    return 0;
  } catch (error) {
    const message = error instanceof Error ? error.message : "Wrangler returned an unreadable Worker secret list.";
    console.error(message);
    return 1;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  try {
    process.exitCode = verifyAPNSSecretNames();
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unable to validate APNs Worker secret names.";
    console.error(message);
    process.exitCode = 2;
  }
}
