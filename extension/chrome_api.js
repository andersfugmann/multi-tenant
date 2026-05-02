// chrome_api.js — thin JS helpers for Chrome extension APIs
// Called from OCaml via typed js_of_ocaml bindings.

//Provides: url_router_connect_native
function url_router_connect_native() {
  return chrome.runtime.connectNative("url_router");
}

//Provides: url_router_create_tab
function url_router_create_tab(url) {
  chrome.tabs.create({ url: url });
}

//Provides: url_router_port_post_message
function url_router_port_post_message(port, msg) {
  port.postMessage(msg);
}

//Provides: url_router_port_on_message
function url_router_port_on_message(port, callback) {
  port.onMessage.addListener(function(msg) {
    callback(msg);
  });
}

//Provides: url_router_port_on_disconnect
function url_router_port_on_disconnect(port, callback) {
  port.onDisconnect.addListener(function() {
    callback();
  });
}

//Provides: url_router_on_before_navigate
function url_router_on_before_navigate(callback) {
  chrome.webNavigation.onBeforeNavigate.addListener(function(details) {
    callback(details.url, details.tabId, details.frameId);
  });
}

//Provides: url_router_create_context_menu
function url_router_create_context_menu(id, title, contexts) {
  chrome.contextMenus.create({
    id: id,
    title: title,
    contexts: contexts
  });
}

//Provides: url_router_on_context_menu_clicked
function url_router_on_context_menu_clicked(callback) {
  chrome.contextMenus.onClicked.addListener(function(info, tab) {
    var menu_id = info.menuItemId;
    var link_url = info.linkUrl || "";
    var page_url = info.pageUrl || "";
    callback(menu_id, link_url, page_url);
  });
}

//Provides: url_router_on_installed
function url_router_on_installed(callback) {
  chrome.runtime.onInstalled.addListener(function(_details) {
    callback();
  });
}

//Provides: url_router_on_startup
function url_router_on_startup(callback) {
  chrome.runtime.onStartup.addListener(function() {
    callback();
  });
}

//Provides: url_router_on_message_external
function url_router_on_message_external(callback) {
  chrome.runtime.onMessage.addListener(function(message, _sender, sendResponse) {
    callback(message, sendResponse);
    return true;
  });
}

//Provides: url_router_get_last_error
function url_router_get_last_error() {
  var err = chrome.runtime.lastError;
  if (err && err.message) {
    return err.message;
  }
  return "";
}

//Provides: url_router_log
function url_router_log(msg) {
  console.log("[url-router] " + msg);
}

//Provides: url_router_set_timeout
function url_router_set_timeout(callback, ms) {
  setTimeout(callback, ms);
}
