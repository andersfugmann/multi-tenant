// popup.js — thin UI for the URL Router extension popup

var statusDot = document.getElementById("statusDot");
var statusText = document.getElementById("statusText");
var statusPanel = document.getElementById("statusPanel");
var uptimeEl = document.getElementById("uptime");
var tenantList = document.getElementById("tenantList");

function setStatus(connected, text) {
  statusDot.className = "dot " + (connected ? "connected" : "disconnected");
  statusText.textContent = text;
}

function formatUptime(seconds) {
  var h = Math.floor(seconds / 3600);
  var m = Math.floor((seconds % 3600) / 60);
  var s = seconds % 60;
  var parts = [];
  if (h > 0) parts.push(h + "h");
  if (m > 0) parts.push(m + "m");
  parts.push(s + "s");
  return parts.join(" ");
}

// Ask background for current connection state
chrome.runtime.sendMessage({ action: "get_status" }, function(response) {
  if (chrome.runtime.lastError || !response) {
    setStatus(false, "Not connected");
    return;
  }
  setStatus(response.connected, response.connected ? "Connected" : "Disconnected");
});

document.getElementById("btnStatus").addEventListener("click", function() {
  // Fetch both status (connected tenants) and config (all known tenants) in parallel
  var pending = 2;
  var statusData = null;
  var configData = null;

  function render() {
    if (pending > 0) return;
    statusPanel.style.display = "block";
    tenantList.innerHTML = "";

    // Uptime
    if (statusData && statusData.uptime_seconds !== undefined) {
      uptimeEl.textContent = "Daemon uptime: " + formatUptime(statusData.uptime_seconds);
    } else {
      uptimeEl.textContent = "";
    }

    // Build set of connected tenant IDs
    var connected = {};
    if (statusData && statusData.registered_tenants) {
      statusData.registered_tenants.forEach(function(t) { connected[t] = true; });
    }

    // Build combined tenant map: known (from config) + connected
    var tenants = {};
    if (configData && configData.tenants) {
      Object.keys(configData.tenants).forEach(function(id) {
        tenants[id] = {
          label: configData.tenants[id].label || "",
          brand: configData.tenants[id].brand || "",
          connected: !!connected[id]
        };
      });
    }
    // Add any connected tenants not yet in config
    Object.keys(connected).forEach(function(id) {
      if (!tenants[id]) {
        tenants[id] = { label: "", brand: "", connected: true };
      }
    });

    var ids = Object.keys(tenants).sort();
    if (ids.length === 0) {
      tenantList.innerHTML = "<li style='color:#5f6368'>No tenants</li>";
      return;
    }
    ids.forEach(function(id) {
      var t = tenants[id];
      var li = document.createElement("li");

      var dot = document.createElement("span");
      dot.className = "dot " + (t.connected ? "connected" : "disconnected");
      li.appendChild(dot);

      var name = document.createElement("span");
      name.className = "tenant-name";
      name.textContent = id;
      li.appendChild(name);

      var detail = t.label || t.brand;
      if (detail) {
        var lbl = document.createElement("span");
        lbl.className = "tenant-label";
        lbl.textContent = detail;
        li.appendChild(lbl);
      }
      tenantList.appendChild(li);
    });
  }

  chrome.runtime.sendMessage({ action: "query_status" }, function(response) {
    if (!chrome.runtime.lastError && response && response.data) {
      // Wire response is ["Ok_status", { registered_tenants, uptime_seconds }]
      var payload = response.data;
      if (Array.isArray(payload) && payload.length === 2) {
        statusData = payload[1];
      }
    }
    pending--;
    render();
  });

  chrome.runtime.sendMessage({ action: "query_config" }, function(response) {
    if (!chrome.runtime.lastError && response && response.data) {
      // Wire response is ["Ok_config", { tenants, rules, ... }]
      var payload = response.data;
      if (Array.isArray(payload) && payload.length === 2) {
        configData = payload[1];
      }
    }
    pending--;
    render();
  });
});

document.getElementById("btnConfig").addEventListener("click", function() {
  chrome.tabs.create({ url: chrome.runtime.getURL("config.html") });
  window.close();
});

document.getElementById("btnReconnect").addEventListener("click", function() {
  chrome.runtime.sendMessage({ action: "reconnect" }, function(response) {
    if (chrome.runtime.lastError || !response) {
      setStatus(false, "Error reconnecting");
      return;
    }
    setStatus(response.connected, response.connected ? "Connected" : "Disconnected");
  });
});
