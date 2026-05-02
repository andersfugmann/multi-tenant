// add_rule.js — UI logic for the Add Rule dialog

var patternInput = document.getElementById("pattern");
var tenantSelect = document.getElementById("tenant");
var errorDiv = document.getElementById("error");

// Pre-fill pattern from URL params (set by context menu)
var params = new URLSearchParams(window.location.search);
var prefillUrl = params.get("url");
if (prefillUrl) {
  try {
    var u = new URL(prefillUrl);
    patternInput.value = u.origin.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "/.*";
  } catch (_e) {
    patternInput.value = "";
  }
}

// Fetch tenants from config via background script
chrome.runtime.sendMessage({ action: "query_config" }, function(response) {
  if (chrome.runtime.lastError || !response || !response.data) {
    tenantSelect.innerHTML = '<option value="">Failed to load</option>';
    return;
  }
  // response.data is the wire response; extract config from Ok_config
  var data = response.data;
  var config = null;
  // Wire format: ["Ok_config", { ...config }]
  if (Array.isArray(data) && data.length === 2 && data[0] === "Ok_config") {
    config = data[1];
  }
  if (!config || !config.tenants) {
    tenantSelect.innerHTML = '<option value="">No tenants</option>';
    return;
  }
  tenantSelect.innerHTML = "";
  // tenants is a JSON object keyed by tenant ID
  var tenants = config.tenants;
  if (tenants && typeof tenants === "object") {
    Object.keys(tenants).forEach(function(name) {
      var opt = document.createElement("option");
      opt.value = name;
      opt.textContent = tenants[name].label || name;
      tenantSelect.appendChild(opt);
    });
  }
});

document.getElementById("btnCancel").addEventListener("click", function() {
  window.close();
});

document.getElementById("btnSave").addEventListener("click", function() {
  var pattern = patternInput.value.trim();
  var tenant = tenantSelect.value;
  errorDiv.textContent = "";

  if (!pattern) {
    errorDiv.textContent = "Pattern is required.";
    return;
  }
  if (!tenant) {
    errorDiv.textContent = "Select a tenant.";
    return;
  }

  // Validate regex
  try {
    new RegExp(pattern);
  } catch (e) {
    errorDiv.textContent = "Invalid regex: " + e.message;
    return;
  }

  chrome.runtime.sendMessage({
    action: "add_rule",
    pattern: pattern,
    target: tenant
  }, function(response) {
    if (chrome.runtime.lastError) {
      errorDiv.textContent = "Error: " + chrome.runtime.lastError.message;
      return;
    }
    if (response && response.error) {
      errorDiv.textContent = "Error: " + response.error;
      return;
    }
    window.close();
  });
});
