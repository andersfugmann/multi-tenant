/**
 * Background service worker — navigation interception and native messaging.
 *
 * This is the main entry point for the extension. It:
 * 1. Maintains a persistent native messaging connection to the daemon
 * 2. Intercepts navigations via webNavigation.onBeforeNavigate
 * 3. Sends `open <url>` to the daemon for routing decisions
 * 4. Kills tabs on REMOTE responses
 * 5. Updates the toolbar badge with tenant ownership info
 */

import { DaemonClient } from "./daemon-client.js";
import type { Config } from "./protocol.js";
import { buildContextMenus, handleContextMenuClick } from "./menu.js";
import { updateBadge, clearBadge } from "./badge.js";

const client = new DaemonClient();
let cachedConfig: Config | null = null;

/** Initialize: connect to daemon and load config. */
async function initialize(): Promise<void> {
  client.connect();

  client.onDisconnect(() => {
    console.warn("url-router: native host disconnected, reconnecting...");
    setTimeout(() => {
      client.connect();
      loadConfig().catch(() => {});
    }, 1000);
  });

  await loadConfig();
}

/** Fetch config from daemon and rebuild UI. */
async function loadConfig(): Promise<void> {
  try {
    cachedConfig = await client.getConfig();
    buildContextMenus(cachedConfig);
  } catch (e) {
    console.error("url-router: failed to load config:", e);
  }
}

/** Kill a tab (new tab) or go back (existing tab). */
function killTab(tabId: number): void {
  chrome.tabs.get(tabId).then((tab) => {
    if (!tab.url || tab.url === "about:blank" || tab.url === "chrome://newtab/") {
      chrome.tabs.remove(tabId);
    } else {
      chrome.tabs.goBack(tabId);
    }
  }).catch(() => {
    // Tab may already be closed
  });
}

// --- Navigation interception ---

chrome.webNavigation.onBeforeNavigate.addListener(
  (details) => {
    if (details.frameId !== 0) return;

    const url = details.url;
    if (!url.startsWith("http://") && !url.startsWith("https://")) return;

    const tabId = details.tabId;

    client
      .open(url)
      .then((response) => {
        switch (response.status) {
          case "REMOTE":
            killTab(tabId);
            break;
          case "LOCAL":
          case "FALLBACK":
            break;
          case "ERR":
            console.error("url-router: routing error:", response.message);
            break;
        }
      })
      .catch((e: unknown) => {
        console.error("url-router: open failed:", e);
      });
  }
);

// --- Badge updates ---

chrome.webNavigation.onCompleted.addListener(
  (details) => {
    if (details.frameId !== 0) return;

    const url = details.url;
    if (!url.startsWith("http://") && !url.startsWith("https://")) {
      clearBadge(details.tabId);
      return;
    }

    client
      .test(url)
      .then((response) => {
        if (response.status === "MATCH") {
          updateBadge(details.tabId, response.tenant, cachedConfig);
        } else {
          clearBadge(details.tabId);
        }
      })
      .catch(() => {
        clearBadge(details.tabId);
      });
  }
);

// --- Context menus ---

chrome.contextMenus.onClicked.addListener(
  (info) => {
    handleContextMenuClick(info, client);
  }
);

// --- Internal message handler ---

type InternalMessage =
  | { readonly type: "getConfig" }
  | { readonly type: "setConfig"; readonly config: Config }
  | { readonly type: "openOn"; readonly tenant: string; readonly url: string }
  | { readonly type: "addRule"; readonly pattern: string; readonly tenant: string }
  | { readonly type: "test"; readonly url: string };

chrome.runtime.onMessage.addListener(
  (message: InternalMessage, _sender, sendResponse) => {
    handleInternalMessage(message).then(sendResponse);
    return true; // keep channel open for async response
  }
);

async function handleInternalMessage(message: InternalMessage): Promise<unknown> {
  switch (message.type) {
    case "getConfig":
      if (!cachedConfig) {
        await loadConfig();
      }
      return cachedConfig;
    case "setConfig": {
      const result = await client.setConfig(message.config);
      await loadConfig();
      return result;
    }
    case "openOn":
      return client.openOn(message.tenant, message.url);
    case "addRule": {
      const result = await client.addRule(message.pattern, message.tenant);
      await loadConfig();
      return result;
    }
    case "test":
      return client.test(message.url);
  }
}

// --- Initialization ---

initialize().catch((e: unknown) => {
  console.error("url-router: initialization failed:", e);
});
