"use strict";

document.addEventListener("DOMContentLoaded", function () {
  var nameInput = document.getElementById("tenantName");
  var socketInput = document.getElementById("socketPath");
  var statusMsg = document.getElementById("statusMsg");
  var btnSave = document.getElementById("btnSave");
  var btnClose = document.getElementById("btnClose");

  // Load saved values
  chrome.storage.local.get(["tenant_name", "socket_path"], function (items) {
    nameInput.value = items.tenant_name || "";
    socketInput.value = items.socket_path || "";
  });

  function showStatus(text, isError) {
    statusMsg.textContent = text;
    statusMsg.className = "msg " + (isError ? "error" : "success");
    setTimeout(function () { statusMsg.textContent = ""; }, 2500);
  }

  btnSave.addEventListener("click", function () {
    chrome.storage.local.set({
      tenant_name: nameInput.value.trim(),
      socket_path: socketInput.value.trim()
    }, function () {
      showStatus("Saved — reconnect the bridge for changes to take effect.", false);
    });
  });

  btnClose.addEventListener("click", function () {
    window.close();
  });
});
