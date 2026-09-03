import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("desktop source lists include public catalogs and never name the QuakeSignal worker", async () => {
  const types = await readFile(resolve(root, "src/types.ts"), "utf8");
  assert.match(types, /usgs_eqlist/);
  assert.match(types, /emsc_eqlist/);
  assert.match(types, /geonet_eqlist/);
  assert.match(types, /cenc_eew/);

  const rust = await readFile(resolve(root, "src-tauri/src/lib.rs"), "utf8");
  assert.match(rust, /catalog::spawn_all/);
  assert.doesNotMatch(rust, /quakesignal-api|hopeso\.workers\.dev/);

  const wolfx = await readFile(resolve(root, "src-tauri/src/wolfx_client.rs"), "utf8");
  assert.match(wolfx, /wss:\/\/ws-api\.wolfx\.jp/);
  assert.match(wolfx, /https:\/\/api\.wolfx\.jp/);
  assert.doesNotMatch(wolfx, /quakesignal-api|hopeso\.workers\.dev/);

  const catalog = await readFile(resolve(root, "src-tauri/src/catalog.rs"), "utf8");
  assert.match(catalog, /earthquake\.usgs\.gov/);
  assert.match(catalog, /seismicportal\.eu/);
  assert.match(catalog, /api\.geonet\.org\.nz/);
  assert.doesNotMatch(catalog, /quakesignal-api|hopeso\.workers\.dev/);
});
