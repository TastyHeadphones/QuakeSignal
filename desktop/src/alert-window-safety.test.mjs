import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("the emergency window never presents an invented shaking countdown", async () => {
  const [source, markup] = await Promise.all([
    readFile(new URL("./alert.ts", import.meta.url), "utf8"),
    readFile(new URL("../alert.html", import.meta.url), "utf8"),
  ]);

  assert.doesNotMatch(source, /S_WAVE|computeEta|etaSeconds|setInterval/);
  assert.doesNotMatch(markup, /countdown|time until shaking/i);
  assert.match(markup, /id="guidance"/);
});

test("the emergency surfaces expose assertive dialog and alert semantics", async () => {
  const [alertMarkup, mainSource] = await Promise.all([
    readFile(new URL("../alert.html", import.meta.url), "utf8"),
    readFile(new URL("./main.ts", import.meta.url), "utf8"),
  ]);

  assert.match(alertMarkup, /role="alertdialog"/);
  assert.match(alertMarkup, /aria-modal="true"/);
  assert.match(alertMarkup, /aria-labelledby="badge hypocenter"/);
  assert.match(alertMarkup, /aria-describedby="meta guidance tip"/);
  assert.match(mainSource, /level === "alert" \? "alert" : "status"/);
  assert.match(mainSource, /level === "alert" \? "assertive" : "polite"/);
});

test("shared language selection updates the root language for main and alert documents", async () => {
  const [i18nSource, mainSource, alertSource] = await Promise.all([
    readFile(new URL("./i18n.ts", import.meta.url), "utf8"),
    readFile(new URL("./main.ts", import.meta.url), "utf8"),
    readFile(new URL("./alert.ts", import.meta.url), "utf8"),
  ]);

  assert.match(i18nSource, /document\.documentElement\.lang = activeLang/);
  assert.match(mainSource, /setLanguage\(language\)/);
  assert.match(alertSource, /setLanguage\(alert\.lang\)/);
});

test("the alert listener is registered before the initial queued load", async () => {
  const source = await readFile(new URL("./alert.ts", import.meta.url), "utf8");
  const initialize = source.slice(source.indexOf("async function initialize"));

  assert.ok(initialize.indexOf('await listen("alert-updated"') >= 0);
  assert.ok(initialize.indexOf("await enqueueLoad()") > initialize.indexOf('await listen("alert-updated"'));
});
