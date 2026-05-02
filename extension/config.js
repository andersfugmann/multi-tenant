// config.js — Full configuration UI for URL Router extension

var statusDot = document.getElementById("statusDot");
var statusText = document.getElementById("statusText");
var loadingEl = document.getElementById("loading");
var contentEl = document.getElementById("content");
var footerMsg = document.getElementById("footerMsg");

var tenantListEl = document.getElementById("tenantList");
var ruleListEl = document.getElementById("ruleList");
var tenantFormEl = document.getElementById("tenantForm");
var ruleFormEl = document.getElementById("ruleForm");

// Current config state
var config = null;
// Tenant being edited (null = adding new)
var editingTenantId = null;
// Rule being edited (null = adding new, otherwise index)
var editingRuleIndex = null;

// -- Helpers --

function setStatus(connected) {
  statusDot.className = "dot " + (connected ? "ok" : "err");
  statusText.textContent = connected ? "Connected" : "Disconnected";
  statusDot.parentElement.className = "status-badge " + (connected ? "connected" : "disconnected");
}

function showMsg(text, type) {
  footerMsg.textContent = text;
  footerMsg.className = "msg " + (type || "");
  if (type === "success") {
    setTimeout(function() { footerMsg.textContent = ""; }, 3000);
  }
}

function escapeHtml(s) {
  var div = document.createElement("div");
  div.appendChild(document.createTextNode(s));
  return div.innerHTML;
}

// -- Fetch config --

function fetchConfig() {
  chrome.runtime.sendMessage({ action: "query_config" }, function(response) {
    if (chrome.runtime.lastError || !response) {
      setStatus(false);
      loadingEl.textContent = "Failed to connect to extension.";
      return;
    }
    setStatus(response.connected);
    var data = response.data;
    // Wire format: ["Ok_config", {...config}]
    if (Array.isArray(data) && data.length === 2 && data[0] === "Ok_config") {
      config = data[1];
      loadingEl.style.display = "none";
      contentEl.style.display = "block";
      renderTenants();
      renderRules();
      renderDefaults();
    } else {
      loadingEl.textContent = "Failed to load configuration.";
    }
  });
}

// -- Tenant list rendering --

function renderTenants() {
  var tenants = config.tenants || {};
  var keys = Object.keys(tenants);

  if (keys.length === 0) {
    tenantListEl.innerHTML = '<div class="card-empty">No tenants defined. Add a tenant to configure browser profiles.</div>';
    return;
  }

  var html = "";
  keys.forEach(function(id) {
    var t = tenants[id];
    var brandText = t.brand ? t.brand : "";
    html += '<div class="row-item tenant-row">'
      + '<div class="color-swatch" style="background:' + escapeHtml(t.color || "#ccc") + '"></div>'
      + '<div class="tenant-info">'
      + '  <div class="tenant-id">' + escapeHtml(id) + '</div>'
      + '  <div class="tenant-label">' + escapeHtml(t.label || "")
      + (brandText ? ' <span class="tenant-brand">(' + escapeHtml(brandText) + ')</span>' : '')
      + '</div>'
      + '</div>'
      + '<div class="tenant-cmd" title="'
      + escapeHtml(t.browser_cmd || "No launch command \u2014 browser will not be started automatically") + '">'
      + (t.browser_cmd
          ? escapeHtml(t.browser_cmd)
          : '<span style="color:#5f6368;font-style:italic">no launch command</span>')
      + '</div>'
      + '<div class="row-actions">'
      + '  <button class="btn-icon" title="Edit" data-edit-tenant="' + escapeHtml(id) + '">✏️</button>'
      + '  <button class="btn-icon" title="Delete" data-del-tenant="' + escapeHtml(id) + '">🗑️</button>'
      + '</div>'
      + '</div>';
  });
  tenantListEl.innerHTML = html;

  // Bind edit/delete buttons
  tenantListEl.querySelectorAll("[data-edit-tenant]").forEach(function(btn) {
    btn.addEventListener("click", function() { editTenant(btn.dataset.editTenant); });
  });
  tenantListEl.querySelectorAll("[data-del-tenant]").forEach(function(btn) {
    btn.addEventListener("click", function() { deleteTenant(btn.dataset.delTenant); });
  });
}

function editTenant(id) {
  var t = config.tenants[id];
  editingTenantId = id;
  document.getElementById("tfId").value = id;
  document.getElementById("tfId").disabled = true;
  document.getElementById("tfLabel").value = t.label || "";
  document.getElementById("tfColor").value = t.color || "#1a73e8";
  document.getElementById("tfCmd").value = t.browser_cmd || "";
  document.getElementById("tfSave").textContent = "Update tenant";
  tenantFormEl.classList.add("visible");
}

function deleteTenant(id) {
  delete config.tenants[id];
  // Also update rules and defaults that reference this tenant
  renderTenants();
  renderRules();
  populateTenantSelects();
}

function resetTenantForm() {
  editingTenantId = null;
  document.getElementById("tfId").value = "";
  document.getElementById("tfId").disabled = false;
  document.getElementById("tfLabel").value = "";
  document.getElementById("tfColor").value = "#1a73e8";
  document.getElementById("tfCmd").value = "";
  document.getElementById("tfSave").textContent = "Add tenant";
  tenantFormEl.classList.remove("visible");
}

function saveTenant() {
  var id = document.getElementById("tfId").value.trim();
  var label = document.getElementById("tfLabel").value.trim();
  var color = document.getElementById("tfColor").value;
  var cmd = document.getElementById("tfCmd").value.trim();

  if (!id) { showMsg("Tenant ID is required.", "error"); return; }

  // Preserve brand from existing tenant (daemon-managed field)
  var existing = config.tenants[id];
  var entry = { browser_cmd: cmd || null, label: label || id, color: color };
  if (existing && existing.brand) {
    entry.brand = existing.brand;
  }
  config.tenants[id] = entry;
  resetTenantForm();
  renderTenants();
  populateTenantSelects();
}

// -- Rule list rendering --

function renderRules() {
  var rules = config.rules || [];

  if (rules.length === 0) {
    ruleListEl.innerHTML = '<div class="card-empty">No routing rules configured.</div>';
    return;
  }

  var html = "";
  rules.forEach(function(r, i) {
    var onClass = r.enabled ? "on" : "";
    html += '<div class="row-item rule-row">'
      + '<button class="toggle ' + onClass + '" data-toggle-rule="' + i + '"></button>'
      + '<div class="rule-pattern" title="' + escapeHtml(r.pattern) + '">'
      + escapeHtml(r.pattern)
      + '</div>'
      + '<span class="rule-target">→ ' + escapeHtml(r.target) + '</span>'
      + '<div class="row-actions">'
      + '  <button class="btn-icon" title="Edit" data-edit-rule="' + i + '">✏️</button>'
      + '  <button class="btn-icon" title="Delete" data-del-rule="' + i + '">🗑️</button>'
      + '  <button class="btn-icon" title="Move up" data-move-rule-up="' + i + '">↑</button>'
      + '  <button class="btn-icon" title="Move down" data-move-rule-down="' + i + '">↓</button>'
      + '</div>'
      + '</div>';
  });
  ruleListEl.innerHTML = html;

  ruleListEl.querySelectorAll("[data-toggle-rule]").forEach(function(btn) {
    btn.addEventListener("click", function() {
      var idx = parseInt(btn.dataset.toggleRule, 10);
      config.rules[idx].enabled = !config.rules[idx].enabled;
      renderRules();
    });
  });
  ruleListEl.querySelectorAll("[data-edit-rule]").forEach(function(btn) {
    btn.addEventListener("click", function() { editRule(parseInt(btn.dataset.editRule, 10)); });
  });
  ruleListEl.querySelectorAll("[data-del-rule]").forEach(function(btn) {
    btn.addEventListener("click", function() {
      config.rules.splice(parseInt(btn.dataset.delRule, 10), 1);
      renderRules();
    });
  });
  ruleListEl.querySelectorAll("[data-move-rule-up]").forEach(function(btn) {
    btn.addEventListener("click", function() {
      var idx = parseInt(btn.dataset.moveRuleUp, 10);
      if (idx > 0) {
        var tmp = config.rules[idx - 1];
        config.rules[idx - 1] = config.rules[idx];
        config.rules[idx] = tmp;
        renderRules();
      }
    });
  });
  ruleListEl.querySelectorAll("[data-move-rule-down]").forEach(function(btn) {
    btn.addEventListener("click", function() {
      var idx = parseInt(btn.dataset.moveRuleDown, 10);
      if (idx < config.rules.length - 1) {
        var tmp = config.rules[idx + 1];
        config.rules[idx + 1] = config.rules[idx];
        config.rules[idx] = tmp;
        renderRules();
      }
    });
  });
}

function editRule(idx) {
  var r = config.rules[idx];
  editingRuleIndex = idx;
  document.getElementById("rfPattern").value = r.pattern;
  populateRuleTarget(r.target);
  document.getElementById("rfSave").textContent = "Update rule";
  ruleFormEl.classList.add("visible");
}

function resetRuleForm() {
  editingRuleIndex = null;
  document.getElementById("rfPattern").value = "";
  document.getElementById("rfSave").textContent = "Add rule";
  ruleFormEl.classList.remove("visible");
}

function saveRule() {
  var pattern = document.getElementById("rfPattern").value.trim();
  var target = document.getElementById("rfTarget").value;

  if (!pattern) { showMsg("Pattern is required.", "error"); return; }
  if (!target) { showMsg("Select a target tenant.", "error"); return; }

  try { new RegExp(pattern); } catch (e) {
    showMsg("Invalid regex: " + e.message, "error");
    return;
  }

  var rule = { pattern: pattern, target: target, enabled: true };

  if (editingRuleIndex !== null) {
    rule.enabled = config.rules[editingRuleIndex].enabled;
    config.rules[editingRuleIndex] = rule;
  } else {
    config.rules.push(rule);
  }

  resetRuleForm();
  renderRules();
}

function populateRuleTarget(selected) {
  var sel = document.getElementById("rfTarget");
  sel.innerHTML = "";
  Object.keys(config.tenants || {}).forEach(function(id) {
    var opt = document.createElement("option");
    opt.value = id;
    opt.textContent = config.tenants[id].label || id;
    opt.selected = (id === selected);
    sel.appendChild(opt);
  });
}

// -- Defaults --

function renderDefaults() {
  var d = config.defaults || {};
  document.getElementById("dfCooldown").value = d.cooldown_seconds || 5;
  document.getElementById("dfTimeout").value = d.browser_launch_timeout || 10;
  populateTenantSelects();
}

function populateTenantSelects() {
  var unmatched = document.getElementById("dfUnmatched");
  var currentVal = unmatched.value || (config.defaults && config.defaults.unmatched) || "";
  unmatched.innerHTML = "";
  // "local" is always an option
  var localOpt = document.createElement("option");
  localOpt.value = "local";
  localOpt.textContent = "Local (no rerouting)";
  localOpt.selected = (currentVal === "local");
  unmatched.appendChild(localOpt);

  Object.keys(config.tenants || {}).forEach(function(id) {
    var opt = document.createElement("option");
    opt.value = id;
    opt.textContent = config.tenants[id].label || id;
    opt.selected = (id === currentVal);
    unmatched.appendChild(opt);
  });

  // Also refresh rule target dropdown if visible
  populateRuleTarget(document.getElementById("rfTarget").value);
}

function readDefaults() {
  config.defaults = config.defaults || {};
  config.defaults.unmatched = document.getElementById("dfUnmatched").value;
  config.defaults.cooldown_seconds = parseInt(document.getElementById("dfCooldown").value, 10) || 5;
  config.defaults.browser_launch_timeout = parseInt(document.getElementById("dfTimeout").value, 10) || 10;
}

// -- Save config --

function saveConfig() {
  readDefaults();
  showMsg("Saving…", "");

  chrome.runtime.sendMessage({ action: "set_config", config: config }, function(response) {
    if (chrome.runtime.lastError) {
      showMsg("Error: " + chrome.runtime.lastError.message, "error");
      return;
    }
    if (response && response.error) {
      showMsg("Error: " + response.error, "error");
      return;
    }
    showMsg("Configuration saved.", "success");
  });
}

// -- Event bindings --

document.getElementById("btnAddTenant").addEventListener("click", function() {
  resetTenantForm();
  tenantFormEl.classList.add("visible");
});
document.getElementById("tfCancel").addEventListener("click", resetTenantForm);
document.getElementById("tfSave").addEventListener("click", saveTenant);

document.getElementById("btnAddRule").addEventListener("click", function() {
  resetRuleForm();
  populateRuleTarget("");
  ruleFormEl.classList.add("visible");
});
document.getElementById("rfCancel").addEventListener("click", resetRuleForm);
document.getElementById("rfSave").addEventListener("click", saveRule);

document.getElementById("btnSave").addEventListener("click", saveConfig);

// -- Init --
fetchConfig();
