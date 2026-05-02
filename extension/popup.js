// popup.js — thin UI for the URL Router extension popup

const statusDot = document.getElementById("statusDot");
const statusText = document.getElementById("statusText");
const info = document.getElementById("info");

function setStatus(connected, text) {
  statusDot.className = "dot " + (connected ? "connected" : "disconnected");
  statusText.textContent = text;
}

function showInfo(text) {
  info.textContent = text;
}

// Ask background for current connection state
chrome.runtime.sendMessage({ action: "get_status" }, function(response) {
  if (chrome.runtime.lastError || !response) {
    setStatus(false, "Not connected");
    return;
  }
  setStatus(response.connected, response.connected ? "Connected" : "Disconnected");
  if (response.info) {
    showInfo(response.info);
  }
});

document.getElementById("btnStatus").addEventListener("click", function() {
  chrome.runtime.sendMessage({ action: "query_status" }, function(response) {
    if (chrome.runtime.lastError || !response) {
      showInfo("Error fetching status");
      return;
    }
    showInfo(JSON.stringify(response.data, null, 2));
  });
});

document.getElementById("btnConfig").addEventListener("click", function() {
  chrome.tabs.create({ url: chrome.runtime.getURL("config.html") });
  window.close();
});

document.getElementById("btnReconnect").addEventListener("click", function() {
  chrome.runtime.sendMessage({ action: "reconnect" }, function(response) {
    if (chrome.runtime.lastError || !response) {
      showInfo("Error reconnecting");
      return;
    }
    setStatus(response.connected, response.connected ? "Connected" : "Disconnected");
    showInfo("Reconnection attempted");
  });
});

document.getElementById("btnOptions").addEventListener("click", function() {
  chrome.runtime.openOptionsPage();
  window.close();
});
