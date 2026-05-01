/**
 * Toolbar badge management.
 *
 * Shows a colored letter on the extension icon indicating which tenant
 * "owns" the current tab's URL.
 */

import type { Config, Tenant } from "./protocol.js";

/** Update the toolbar badge for a tab based on test results. */
export function updateBadge(
  tabId: number,
  tenantId: string | null,
  config: Config | null
): void {
  if (!tenantId || !config) {
    chrome.action.setBadgeText({ tabId, text: "" });
    return;
  }

  const tenant: Tenant | undefined = config.tenants[tenantId];
  if (!tenant) {
    chrome.action.setBadgeText({ tabId, text: "" });
    return;
  }

  const label = tenant.badge_label ?? tenantId.charAt(0).toUpperCase();
  const color = tenant.badge_color ?? "#666666";

  chrome.action.setBadgeText({ tabId, text: label });
  chrome.action.setBadgeBackgroundColor({ tabId, color });
}

/** Clear the badge for a tab. */
export function clearBadge(tabId: number): void {
  chrome.action.setBadgeText({ tabId, text: "" });
}
