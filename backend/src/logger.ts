import { config } from "./config.js";

type Level = "debug" | "info" | "warn" | "error";

const order: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

function resolveThreshold(): number {
  const configured = order[config.logLevel as Level];
  return configured ?? order.info;
}

export function createLogger(scope: string) {
  const threshold = resolveThreshold();
  const emit = (level: Level, args: unknown[]) => {
    if (order[level] < threshold) return;
    const ts = new Date().toISOString();
    const prefix = `${ts} [${level.toUpperCase()}] [${scope}]`;
    const sink = level === "error" ? console.error : level === "warn" ? console.warn : console.log;
    sink(prefix, ...args);
  };

  return {
    debug: (...args: unknown[]) => emit("debug", args),
    info: (...args: unknown[]) => emit("info", args),
    warn: (...args: unknown[]) => emit("warn", args),
    error: (...args: unknown[]) => emit("error", args),
  };
}
