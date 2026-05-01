/**
 * Settings page — full config editor for rules, tenants, and defaults.
 *
 * Loads config via background worker, presents editable UI,
 * saves the entire config back via set-config.
 */

import type { Config } from "./protocol.js";

// --- Background communication ---

type SettingsMessage =
  | { readonly type: "getConfig" }
  | { readonly type: "setConfig"; readonly config: Config };

function sendToBackground<T>(message: SettingsMessage): Promise<T> {
  return chrome.runtime.sendMessage(message) as Promise<T>;
}

// --- State ---

let config: Config | null = null;
let saving = false;

// --- Init ---

async function init(): Promise<void> {
  config = await sendToBackground<Config>({ type: "getConfig" });
  if (!config) {
    showStatus("Cannot reach daemon", false);
    return;
  }

  setupTabs();
  renderRules();
  renderTenants();
  renderDefaults();
}

// --- Tabs ---

function setupTabs(): void {
  for (const tab of Array.from(document.querySelectorAll<HTMLButtonElement>(".tab"))) {
    tab.addEventListener("click", () => {
      for (const t of Array.from(document.querySelectorAll(".tab"))) t.classList.remove("active");
      for (const c of Array.from(document.querySelectorAll(".tab-content"))) c.classList.remove("active");
      tab.classList.add("active");
      const target = document.getElementById(`tab-${tab.dataset["tab"]}`);
      if (target) target.classList.add("active");
    });
  }
}

// --- Rules ---

function renderRules(): void {
  if (!config) return;
  const tbody = document.getElementById("rules-body") as HTMLTableSectionElement;
  tbody.innerHTML = "";

  for (let i = 0; i < config.rules.length; i++) {
    const rule = config.rules[i];
    const tr = document.createElement("tr");

    const tdIndex = document.createElement("td");
    tdIndex.textContent = String(i);
    tr.appendChild(tdIndex);

    const tdPattern = document.createElement("td");
    const patternInput = document.createElement("input");
    patternInput.type = "text";
    patternInput.value = rule.pattern;
    patternInput.spellcheck = false;
    patternInput.addEventListener("change", () => {
      if (config) config.rules[i].pattern = patternInput.value;
    });
    tdPattern.appendChild(patternInput);
    tr.appendChild(tdPattern);

    const tdTenant = document.createElement("td");
    const tenantSelect = createTenantSelect(rule.tenant);
    tenantSelect.addEventListener("change", () => {
      if (config) config.rules[i].tenant = tenantSelect.value;
    });
    tdTenant.appendChild(tenantSelect);
    tr.appendChild(tdTenant);

    const tdEnabled = document.createElement("td");
    const enabledCb = document.createElement("input");
    enabledCb.type = "checkbox";
    enabledCb.checked = rule.enabled !== false;
    enabledCb.addEventListener("change", () => {
      if (config) config.rules[i].enabled = enabledCb.checked;
    });
    tdEnabled.appendChild(enabledCb);
    tr.appendChild(tdEnabled);

    const tdActions = document.createElement("td");
    tdActions.className = "actions";

    const saveBtn = document.createElement("button");
    saveBtn.textContent = "Save";
    saveBtn.className = "btn-primary btn-small";
    saveBtn.addEventListener("click", () => saveConfig());
    tdActions.appendChild(saveBtn);

    const delBtn = document.createElement("button");
    delBtn.textContent = "✕";
    delBtn.className = "btn-danger btn-small";
    delBtn.addEventListener("click", () => {
      if (config) {
        config.rules.splice(i, 1);
        saveConfig();
      }
    });
    tdActions.appendChild(delBtn);

    tr.appendChild(tdActions);
    tbody.appendChild(tr);
  }

  const addBtn = document.getElementById("add-rule-btn") as HTMLButtonElement;
  addBtn.onclick = () => {
    if (!config) return;
    const tenantIds = Object.keys(config.tenants);
    const defaultTenant = tenantIds.length > 0 ? tenantIds[0] : "host";
    config.rules.push({ pattern: "^https://example\\.com", tenant: defaultTenant, enabled: true, comment: null });
    renderRules();
  };
}

function createTenantSelect(selectedTenant: string): HTMLSelectElement {
  const select = document.createElement("select");
  if (!config) return select;
  for (const [id, tenant] of Object.entries(config.tenants)) {
    const opt = document.createElement("option");
    opt.value = id;
    opt.textContent = tenant.name;
    if (id === selectedTenant) opt.selected = true;
    select.appendChild(opt);
  }
  return select;
}

// --- Tenants ---

function renderTenants(): void {
  if (!config) return;
  const container = document.getElementById("tenants-list") as HTMLElement;
  container.innerHTML = "";

  for (const [id, tenant] of Object.entries(config.tenants)) {
    const card = document.createElement("div");
    card.className = "tenant-card";

    const header = document.createElement("div");
    header.className = "tenant-header";

    const idSpan = document.createElement("span");
    idSpan.className = "tenant-id";
    idSpan.textContent = id;
    header.appendChild(idSpan);

    const delBtn = document.createElement("button");
    delBtn.textContent = "Delete";
    delBtn.className = "btn-danger btn-small";
    delBtn.addEventListener("click", () => {
      if (!config) return;
      const dependentRules = config.rules.filter(r => r.tenant === id);
      if (dependentRules.length > 0) {
        showStatus(`Cannot delete "${id}" — ${dependentRules.length} rule(s) depend on it`, false);
        return;
      }
      if (confirm(`Delete tenant "${id}"?`)) {
        delete config.tenants[id];
        saveConfig();
      }
    });
    header.appendChild(delBtn);
    card.appendChild(header);

    const grid = document.createElement("div");
    grid.className = "tenant-grid";

    grid.appendChild(createField("Name", tenant.name, (v) => { tenant.name = v; }));
    grid.appendChild(createField("Browser command", tenant.browser_cmd, (v) => { tenant.browser_cmd = v; }));
    grid.appendChild(createField("Socket path", tenant.socket, (v) => { tenant.socket = v; }));
    grid.appendChild(createField("Badge label", tenant.badge_label ?? "", (v) => { tenant.badge_label = v || null; }));
    grid.appendChild(createField("Badge color", tenant.badge_color ?? "", (v) => { tenant.badge_color = v || null; }));

    card.appendChild(grid);

    const saveBtn = document.createElement("button");
    saveBtn.textContent = "Save";
    saveBtn.className = "btn-primary btn-small";
    saveBtn.style.marginTop = "8px";
    saveBtn.addEventListener("click", () => saveConfig());
    card.appendChild(saveBtn);

    container.appendChild(card);
  }

  const addBtn = document.getElementById("add-tenant-btn") as HTMLButtonElement;
  addBtn.onclick = () => {
    const id = prompt("Tenant ID (e.g. 'work'):");
    if (!id || !config) return;
    if (config.tenants[id]) {
      showStatus(`Tenant "${id}" already exists`, false);
      return;
    }
    config.tenants[id] = {
      name: id.charAt(0).toUpperCase() + id.slice(1),
      browser_cmd: "xdg-open",
      socket: `/run/url-router/${id}.sock`,
      badge_label: id.charAt(0).toUpperCase(),
      badge_color: "#666666",
    };
    renderTenants();
  };
}

function createField(label: string, value: string, onChange: (v: string) => void): HTMLElement {
  const wrapper = document.createElement("div");

  const lbl = document.createElement("label");
  lbl.textContent = label;
  wrapper.appendChild(lbl);

  const input = document.createElement("input");
  input.type = "text";
  input.value = value;
  input.spellcheck = false;
  input.addEventListener("change", () => onChange(input.value));
  wrapper.appendChild(input);

  return wrapper;
}

// --- Defaults ---

function renderDefaults(): void {
  if (!config) return;
  const defaults = config.defaults ?? { unmatched: "local", notifications: true, notification_timeout_ms: 3000, cooldown_secs: 5 };

  (document.getElementById("def-unmatched") as HTMLInputElement).value = defaults.unmatched;
  (document.getElementById("def-notifications") as HTMLInputElement).checked = defaults.notifications;
  (document.getElementById("def-notif-timeout") as HTMLInputElement).value = String(defaults.notification_timeout_ms);
  (document.getElementById("def-cooldown") as HTMLInputElement).value = String(defaults.cooldown_secs);

  const saveBtn = document.getElementById("save-defaults-btn") as HTMLButtonElement;
  saveBtn.onclick = () => {
    if (!config) return;
    config.defaults = {
      unmatched: (document.getElementById("def-unmatched") as HTMLInputElement).value,
      notifications: (document.getElementById("def-notifications") as HTMLInputElement).checked,
      notification_timeout_ms: parseInt((document.getElementById("def-notif-timeout") as HTMLInputElement).value, 10) || 3000,
      cooldown_secs: parseInt((document.getElementById("def-cooldown") as HTMLInputElement).value, 10) || 5,
    };
    saveConfig();
  };
}

// --- Save ---

async function saveConfig(): Promise<void> {
  if (!config || saving) return;
  saving = true;
  try {
    const response = await sendToBackground<{ status: string }>({ type: "setConfig", config });
    if (response?.status === "OK") {
      showStatus("Configuration saved", true);
      config = await sendToBackground<Config>({ type: "getConfig" });
      renderRules();
      renderTenants();
      renderDefaults();
    } else {
      showStatus(`Save failed: ${JSON.stringify(response)}`, false);
    }
  } catch (e) {
    showStatus(`Save failed: ${e}`, false);
  } finally {
    saving = false;
  }
}

// --- Status ---

function showStatus(msg: string, ok: boolean): void {
  const el = document.getElementById("status") as HTMLElement;
  el.textContent = msg;
  el.className = ok ? "status-ok" : "status-err";
  el.style.display = "block";
  setTimeout(() => { el.style.display = "none"; }, 3000);
}

document.addEventListener("DOMContentLoaded", () => {
  init().catch(console.error);
});
