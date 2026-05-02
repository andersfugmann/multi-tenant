// page_api.js — Minimal JS stubs for Chrome extension page APIs.
// Only contains Chrome-specific APIs with no js_of_ocaml equivalent.
// Called from OCaml via typed externals in page_util.ml.

//Provides: url_router_page_send_message
function url_router_page_send_message(json_str, callback) {
  chrome.runtime.sendMessage(JSON.parse(json_str), function(response) {
    var err = chrome.runtime.lastError ? chrome.runtime.lastError.message : "";
    var resp = response ? JSON.stringify(response) : "null";
    callback(err, resp);
  });
}

//Provides: url_router_page_storage_get
function url_router_page_storage_get(keys_json, callback) {
  chrome.storage.local.get(JSON.parse(keys_json), function(items) {
    callback(JSON.stringify(items || {}));
  });
}

//Provides: url_router_page_storage_set
function url_router_page_storage_set(items_json, callback) {
  chrome.storage.local.set(JSON.parse(items_json), function() {
    callback();
  });
}

//Provides: url_router_page_create_tab
function url_router_page_create_tab(url) {
  chrome.tabs.create({ url: url });
}

//Provides: url_router_page_get_extension_url
function url_router_page_get_extension_url(path) {
  return chrome.runtime.getURL(path);
}
