/**
 * Context menu setup and handling.
 *
 * Creates two context menu groups:
 * - "Send to <tenant>" — forward the current page to another tenant
 * - "Assign tenant…" — open a dialog to create a routing rule
 *
 * Rebuilds menus when config changes.
 */

import type { Config } from "./protocol.js";
import type { DaemonClient } from "./daemon-client.js";

const SEND_PREFIX = "url-router-send-to-";
const LINK_PREFIX = "url-router-link-";
const ASSIGN_ID = "url-router-assign-tenant";

/** Create submenu items for each tenant. */
function createTenantSubmenus(
  config: Config,
  prefix: string,
  parentId: string,
  contexts: [chrome.contextMenus.ContextType, ...chrome.contextMenus.ContextType[]]
): void {
  Object.keys(config.tenants).forEach((tenantId) => {
    chrome.contextMenus.create({
      id: `${prefix}${tenantId}`,
      parentId,
      title: tenantId,
      contexts,
    });
  });
}

/** Build context menu items from the current config. */
export function buildContextMenus(config: Config): void {
  chrome.contextMenus.removeAll(() => {
    // --- Page context: "Send to <tenant>" ---
    const sendParent = "url-router-send-parent";
    chrome.contextMenus.create({
      id: sendParent,
      title: "Send to",
      contexts: ["page"],
    });
    createTenantSubmenus(config, SEND_PREFIX, sendParent, ["page"]);

    // --- Page context: "Assign tenant…" ---
    chrome.contextMenus.create({
      id: ASSIGN_ID,
      title: "Assign tenant\u2026",
      contexts: ["page"],
    });

    // --- Link context: "Open link in <tenant>" ---
    const linkParent = "url-router-link-parent";
    chrome.contextMenus.create({
      id: linkParent,
      title: "Open link in",
      contexts: ["link"],
    });
    createTenantSubmenus(config, LINK_PREFIX, linkParent, ["link"]);
  });
}

/** Handle a context menu click. */
export function handleContextMenuClick(
  info: chrome.contextMenus.OnClickData,
  client: DaemonClient
): void {
  const menuItemId = String(info.menuItemId);

  // "Send to <tenant>" — forward current page
  if (menuItemId.startsWith(SEND_PREFIX)) {
    const tenantId = menuItemId.slice(SEND_PREFIX.length);
    const url = info.pageUrl;
    if (!url) return;

    client
      .openOn(tenantId, url)
      .then((response) => {
        if (
          response.status === "OK" ||
          (response.status as string).startsWith("OK")
        ) {
          // Close the tab that was forwarded
          if (info.menuItemId && typeof info.menuItemId === "string") {
            chrome.tabs.query(
              { active: true, currentWindow: true },
              (tabs) => {
                if (tabs[0]?.id) chrome.tabs.remove(tabs[0].id);
              }
            );
          }
        }
      })
      .catch((e: unknown) => {
        console.error("url-router: send-to failed:", e);
      });
    return;
  }

  // "Assign tenant…" — open dialog
  if (menuItemId === ASSIGN_ID) {
    const url = info.pageUrl ?? "";
    openAssignDialog(url);
    return;
  }

  // "Open link in <tenant>" — forward a link
  if (menuItemId.startsWith(LINK_PREFIX)) {
    const tenantId = menuItemId.slice(LINK_PREFIX.length);
    const url = info.linkUrl;
    if (!url) return;

    client.openOn(tenantId, url).catch((e: unknown) => {
      console.error("url-router: open-link-in failed:", e);
    });
    return;
  }
}

/** Open the assign-tenant dialog as a popup window. */
function openAssignDialog(url: string): void {
  const params = new URLSearchParams({ url });
  chrome.windows.create({
    url: `assign.html?${params.toString()}`,
    type: "popup",
    width: 440,
    height: 340,
  });
}
