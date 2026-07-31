import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const dist = join(root, "dist");
const unpacked = join(dist, "unpacked");
const { version } = JSON.parse(readFileSync(join(root, "manifest.json"), "utf8"));
const zip = join(dist, `quakesignal-chrome-v${version}.zip`);
const entries = ["manifest.json", "background.js", "core.js", "offscreen.html", "offscreen.js", "popup.html", "popup.js", "styles.css", "_locales", "icons"];

rmSync(dist, { recursive: true, force: true });
mkdirSync(unpacked, { recursive: true });
for (const entry of entries) {
  const source = join(root, entry);
  if (!existsSync(source)) throw new Error(`Missing package entry: ${entry}`);
  cpSync(source, join(unpacked, entry), { recursive: true });
}
execFileSync("zip", ["-qr", zip, "."], { cwd: unpacked });
console.log(zip);
