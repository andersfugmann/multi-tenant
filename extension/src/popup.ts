/**
 * Popup UI logic — "Open in…" buttons and "Remember" feature.
 *
 * Communicates with the background service worker via chrome.runtime.sendMessage.
 */

import type { Config, Tenant } from "./protocol.js";

/** Internal message types for popup ↔ background communication. */
type PopupMessage =
  | { readonly type: "getConfig" }
  | { readonly type: "openOn"; readonly tenant: string; readonly url: string }
  | {
      readonly type: "addRule";
      readonly pattern: string;
      readonly tenant: string;
    }
  | { readonly type: "test"; readonly url: string };

async function initPopup(): Promise<void> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const currentUrl = tab?.url ?? "";

  if (!currentUrl.startsWith("http://") && !currentUrl.startsWith("https://")) {
    showMessage("Not an HTTP page");
    return;
  }

  // Display current URL
  const urlEl = document.getElementById("current-url") as HTMLElement;
  urlEl.textContent = truncateUrl(currentUrl, 60);
  urlEl.title = currentUrl;

  // Load config from background
  const config = await sendToBackground<Config>({ type: "getConfig" });
  if (!config) {
    showMessage("Cannot reach daemon");
    return;
  }

  // Build tenant buttons
  const container = document.getElementById("tenant-buttons") as HTMLElement;
  for (const [tenantId, tenant] of Object.entries(config.tenants)) {
    const btn = createTenantButton(tenantId, tenant, currentUrl);
    container.appendChild(btn);
  }

  // Remember button
  const rememberBtn = document.getElementById("remember-btn") as HTMLButtonElement;
  rememberBtn.addEventListener("click", () => {
    handleRemember(currentUrl, config);
  });
}

function createTenantButton(
  tenantId: string,
  tenant: Tenant,
  url: string
): HTMLButtonElement {
  const btn = document.createElement("button");
  btn.className = "tenant-btn";
  btn.textContent = `Open in ${tenant.name}`;
  if (tenant.badge_color) {
    btn.style.borderLeft = `4px solid ${tenant.badge_color}`;
  }

  btn.addEventListener("click", async () => {
    btn.disabled = true;
    btn.textContent = "Opening…";
    try {
      await sendToBackground({ type: "openOn", tenant: tenantId, url });
      window.close();
    } catch {
      btn.textContent = "Failed";
      setTimeout(() => {
        btn.textContent = `Open in ${tenant.name}`;
        btn.disabled = false;
      }, 2000);
    }
  });

  return btn;
}

async function handleRemember(url: string, config: Config): Promise<void> {
  // Show tenant picker for remembering
  const container = document.getElementById("remember-section") as HTMLElement;
  container.innerHTML = "<p>Remember for which tenant?</p>";

  for (const [tenantId, tenant] of Object.entries(config.tenants)) {
    const btn = document.createElement("button");
    btn.className = "tenant-btn remember-choice";
    btn.textContent = tenant.name;

    btn.addEventListener("click", async () => {
      const origin = new URL(url).origin;
      const pattern = `^${escapeRegex(origin)}(/|$)`;

      try {
        await sendToBackground({
          type: "addRule",
          pattern,
          tenant: tenantId,
        });
        showMessage(`Rule added: ${origin} → ${tenant.name}`);
      } catch {
        showMessage("Failed to add rule");
      }
    });

    container.appendChild(btn);
  }
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function truncateUrl(url: string, maxLen: number): string {
  return url.length > maxLen ? url.slice(0, maxLen) + "…" : url;
}

function showMessage(msg: string): void {
  const el = document.getElementById("message") as HTMLElement;
  el.textContent = msg;
  el.style.display = "block";
}

function sendToBackground<T>(message: PopupMessage): Promise<T> {
  return chrome.runtime.sendMessage(message) as Promise<T>;
}

document.addEventListener("DOMContentLoaded", () => {
  initPopup().catch(console.error);
});
