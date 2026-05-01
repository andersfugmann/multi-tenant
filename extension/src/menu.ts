/**
 * Context menu setup and handling.
 *
 * Creates "Open in <tenant>" context menu items from config.
 * Rebuilds menus when config changes.
 */

import type { Config } from "./protocol.js";
import type { DaemonClient } from "./daemon-client.js";

const MENU_PREFIX = "url-router-open-in-";

/** Build context menu items from the current config. */
export function buildContextMenus(config: Config): void {
  chrome.contextMenus.removeAll(() => {
    for (const [tenantId, tenant] of Object.entries(config.tenants)) {
      chrome.contextMenus.create({
        id: `${MENU_PREFIX}${tenantId}`,
        title: `Open in ${tenant.name}`,
        contexts: ["link"],
      });
    }
  });
}

/** Handle a context menu click. */
export function handleContextMenuClick(
  info: chrome.contextMenus.OnClickData,
  client: DaemonClient
): void {
  const menuItemId = String(info.menuItemId);
  if (!menuItemId.startsWith(MENU_PREFIX)) return;

  const tenantId = menuItemId.slice(MENU_PREFIX.length);
  const url = info.linkUrl;
  if (!url) return;

  client.openOn(tenantId, url).catch((e: unknown) => {
    console.error("url-router: open-on failed:", e);
  });
}
