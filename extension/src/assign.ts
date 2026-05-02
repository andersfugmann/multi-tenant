/**
 * Assign-tenant dialog logic.
 *
 * Opened as a popup window from the context menu. Lets the user pick a tenant
 * and edit the regex pattern, then persists the rule via the background worker.
 */

import type { Config } from "./protocol.js";

/** Messages sent to the background service worker. */
type AssignMessage =
  | { readonly type: "getConfig" }
  | { readonly type: "addRule"; readonly pattern: string; readonly tenant: string }
  | { readonly type: "openOn"; readonly tenant: string; readonly url: string };

function sendToBackground<T>(message: AssignMessage): Promise<T> {
  return chrome.runtime.sendMessage(message) as Promise<T>;
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Extract origin from a URL and build a default regex pattern. */
function defaultPattern(url: string): string {
  try {
    const origin = new URL(url).origin;
    return `^${escapeRegex(origin)}(/|$)`;
  } catch {
    return `^${escapeRegex(url)}`;
  }
}

async function initAssign(): Promise<void> {
  const params = new URLSearchParams(window.location.search);
  const url = params.get("url") ?? "";

  // Show URL
  const preview = document.getElementById("url-preview") as HTMLElement;
  preview.textContent = url;
  preview.title = url;

  // Pre-fill pattern
  const patternInput = document.getElementById("pattern-input") as HTMLInputElement;
  patternInput.value = defaultPattern(url);

  // Load config to populate tenant dropdown
  const config = await sendToBackground<Config>({ type: "getConfig" });
  if (!config) {
    showMessage("Cannot reach daemon", false);
    return;
  }

  const select = document.getElementById("tenant-select") as HTMLSelectElement;
  for (const tenantId of Object.keys(config.tenants)) {
    const option = document.createElement("option");
    option.value = tenantId;
    option.textContent = tenantId;
    select.appendChild(option);
  }

  // Wire up buttons
  const saveBtn = document.getElementById("save-btn") as HTMLButtonElement;
  const cancelBtn = document.getElementById("cancel-btn") as HTMLButtonElement;
  const alsoOpen = document.getElementById("also-open") as HTMLInputElement;

  cancelBtn.addEventListener("click", () => window.close());

  saveBtn.addEventListener("click", async () => {
    const tenant = select.value;
    const pattern = patternInput.value.trim();

    if (!pattern) {
      showMessage("Pattern cannot be empty", false);
      return;
    }

    // Validate regex
    try {
      new RegExp(pattern);
    } catch {
      showMessage("Invalid regex pattern", false);
      return;
    }

    saveBtn.disabled = true;
    saveBtn.textContent = "Saving\u2026";

    try {
      await sendToBackground({ type: "addRule", pattern, tenant });

      if (alsoOpen.checked) {
        await sendToBackground({ type: "openOn", tenant, url });
      }

      showMessage("Rule saved", true);
      setTimeout(() => window.close(), 600);
    } catch {
      showMessage("Failed to save rule", false);
      saveBtn.disabled = false;
      saveBtn.textContent = "Save Rule";
    }
  });
}

function showMessage(msg: string, ok: boolean): void {
  const el = document.getElementById("message") as HTMLElement;
  el.textContent = msg;
  el.className = ok ? "msg-ok" : "msg-err";
  el.style.display = "block";
}

document.addEventListener("DOMContentLoaded", () => {
  initAssign().catch(console.error);
});
