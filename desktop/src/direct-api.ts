import { invoke } from "@tauri-apps/api/core";

// This module is loaded only by direct-distribution builds. Keeping the
// synthetic alarm outside the shared API surface lets the Mac App Store build
// omit both the frontend invoke string and its direct-only control entirely.
export function sendTestAlert(): Promise<void> {
  return invoke<void>("send_test_alert");
}
