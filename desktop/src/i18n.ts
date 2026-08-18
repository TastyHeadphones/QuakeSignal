import { en, type LocaleKey } from "./locales/en";
import { ja } from "./locales/ja";
import { zhHans } from "./locales/zhHans";

const TABLES: Record<string, Record<LocaleKey, string>> = {
  en,
  ja,
  "zh-Hans": zhHans,
};

let activeTable: Record<LocaleKey, string> = en;
let activeLang = "en";

function systemLang(): string {
  const nav = navigator.language || "en";
  if (nav.startsWith("ja")) return "ja";
  if (nav.startsWith("zh")) return "zh-Hans";
  return "en";
}

/** `settingsLanguage` is "system" | "en" | "ja" | "zh-Hans". */
export function setLanguage(settingsLanguage: string) {
  const requestedLang = settingsLanguage === "system" ? systemLang() : settingsLanguage;
  activeLang = TABLES[requestedLang] ? requestedLang : "en";
  activeTable = TABLES[activeLang];
  document.documentElement.lang = activeLang;
}

export function currentLang(): string {
  return activeLang;
}

export function t(key: LocaleKey, vars?: Record<string, string | number>): string {
  let text = activeTable[key] ?? en[key] ?? key;
  if (vars) {
    for (const [k, v] of Object.entries(vars)) {
      text = text.replace(`{${k}}`, String(v));
    }
  }
  return text;
}
