// chrome_api.js — thin JS helpers for Chrome extension APIs
// Called from OCaml via typed js_of_ocaml bindings.
// JSON marshaling happens here to avoid Js.Unsafe in OCaml.

//Provides: url_router_connect_native
function url_router_connect_native() {
  return chrome.runtime.connectNative("url_router");
}

//Provides: url_router_create_tab
function url_router_create_tab(url) {
  chrome.tabs.create({ url: url });
}

//Provides: url_router_port_post_message_json
function url_router_port_post_message_json(port, json_str) {
  port.postMessage(JSON.parse(json_str));
}

//Provides: url_router_port_on_message_json
function url_router_port_on_message_json(port, callback) {
  port.onMessage.addListener(function(msg) {
    callback(JSON.stringify(msg));
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

//Provides: url_router_create_child_context_menu
function url_router_create_child_context_menu(id, parent_id, title, contexts) {
  chrome.contextMenus.create({
    id: id,
    parentId: parent_id,
    title: title,
    contexts: contexts
  });
}

//Provides: url_router_remove_all_context_menus
function url_router_remove_all_context_menus(callback) {
  chrome.contextMenus.removeAll(function() {
    callback();
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

//Provides: url_router_on_message_json
function url_router_on_message_json(callback) {
  chrome.runtime.onMessage.addListener(function(message, _sender, sendResponse) {
    callback(JSON.stringify(message), function(resp_json) {
      sendResponse(JSON.parse(resp_json));
    });
    return true;
  });
}

//Provides: url_router_get_browser_brand
function url_router_get_browser_brand() {
  if (typeof navigator !== "undefined" && navigator.userAgentData
      && navigator.userAgentData.brands) {
    var dominated = ["Chromium", "Not;A=Brand", "Not A;Brand", "Not_A Brand",
                     "Not/A)Brand", "Not)A;Brand"];
    var dominated_set = {};
    for (var i = 0; i < dominated.length; i++) {
      dominated_set[dominated[i]] = true;
    }
    var brands = navigator.userAgentData.brands;
    for (var j = 0; j < brands.length; j++) {
      if (!dominated_set[brands[j].brand]) {
        return brands[j].brand;
      }
    }
    if (brands.length > 0) {
      return brands[0].brand;
    }
  }
  return "";
}

//Provides: url_router_log
function url_router_log(msg) {
  console.log("[url-router] " + msg);
}

//Provides: url_router_create_window
function url_router_create_window(url) {
  chrome.windows.create({
    url: url,
    type: "popup",
    width: 420,
    height: 300
  });
}

//Provides: url_router_set_timeout
function url_router_set_timeout(callback, ms) {
  setTimeout(callback, ms);
}

//Provides: url_router_storage_get
function url_router_storage_get(callback) {
  chrome.storage.local.get(["tenant_name", "socket_path"], function(items) {
    var name = items.tenant_name || "";
    var socket = items.socket_path || "";
    callback(name, socket);
  });
}
