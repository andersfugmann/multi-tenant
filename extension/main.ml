open Base
open Stdio
open Js_of_ocaml

(* Suppress unused open *)
let () = ignore (print_endline : string -> unit)

(* -- JS primitive externals (bound to chrome_api.js) *)

external connect_native_js : unit -> 'a = "url_router_connect_native"
external create_tab_js : Js.js_string Js.t -> unit = "url_router_create_tab"

external port_post_message_json_js :
  'a -> Js.js_string Js.t -> unit
  = "url_router_port_post_message_json"

external port_on_message_json_js :
  'a -> (Js.js_string Js.t -> unit) Js.callback -> unit
  = "url_router_port_on_message_json"

external port_on_disconnect_js : 'a -> (unit -> unit) Js.callback -> unit
  = "url_router_port_on_disconnect"

external on_before_navigate_js :
  (Js.js_string Js.t -> int -> int -> unit) Js.callback -> unit
  = "url_router_on_before_navigate"

external create_context_menu_js :
  Js.js_string Js.t ->
  Js.js_string Js.t ->
  Js.js_string Js.t Js.js_array Js.t ->
  unit = "url_router_create_context_menu"

external create_child_context_menu_js :
  Js.js_string Js.t ->
  Js.js_string Js.t ->
  Js.js_string Js.t ->
  Js.js_string Js.t Js.js_array Js.t ->
  unit = "url_router_create_child_context_menu"

external remove_all_context_menus_js :
  (unit -> unit) Js.callback ->
  unit = "url_router_remove_all_context_menus"

external on_context_menu_clicked_js :
  ( Js.js_string Js.t ->
    Js.js_string Js.t ->
    Js.js_string Js.t ->
    unit)
  Js.callback ->
  unit = "url_router_on_context_menu_clicked"

external on_installed_js : (unit -> unit) Js.callback -> unit
  = "url_router_on_installed"

external on_startup_js : (unit -> unit) Js.callback -> unit
  = "url_router_on_startup"

external on_message_json_js :
  (Js.js_string Js.t -> (Js.js_string Js.t -> unit) -> unit)
  Js.callback ->
  unit = "url_router_on_message_json"

external log_js : Js.js_string Js.t -> unit = "url_router_log"

external get_browser_brand_js : unit -> Js.js_string Js.t = "url_router_get_browser_brand"

external create_window_js : Js.js_string Js.t -> unit = "url_router_create_window"

(* -- Logging *)

let log msg = log_js (Js.string msg)

(* -- JSON conversion *)

let json_of_string (s : string) : (Yojson.Safe.t, string) Result.t =
  Protocol.parse_json_string s

let json_to_string (json : Yojson.Safe.t) : string =
  Yojson.Safe.to_string json

let string_field (json : Yojson.Safe.t) (key : string) :
    (string, string) Result.t =
  match json with
  | `Assoc pairs ->
    (match List.Assoc.find pairs ~equal:String.equal key with
     | Some (`String s) -> Ok s
     | Some _ -> Error (Printf.sprintf "field %s: expected string" key)
     | None -> Error (Printf.sprintf "missing field: %s" key))
  | _ -> Error "expected JSON object"

(* -- Typed wrappers around Chrome APIs *)

let create_tab (url : string) : unit = create_tab_js (Js.string url)

let on_before_navigate (f : string -> int -> int -> unit) : unit =
  on_before_navigate_js
    (Js.wrap_callback (fun url tab_id frame_id ->
       f (Js.to_string url) tab_id frame_id))

let create_context_menu (id : string) (title : string)
    (contexts : string list) : unit =
  let contexts_arr =
    contexts
    |> List.map ~f:Js.string
    |> Array.of_list
    |> Js.array
  in
  create_context_menu_js (Js.string id) (Js.string title) contexts_arr

let create_child_context_menu (id : string) (parent_id : string)
    (title : string) (contexts : string list) : unit =
  let contexts_arr =
    contexts
    |> List.map ~f:Js.string
    |> Array.of_list
    |> Js.array
  in
  create_child_context_menu_js (Js.string id) (Js.string parent_id)
    (Js.string title) contexts_arr

let remove_all_context_menus (callback : unit -> unit) : unit =
  remove_all_context_menus_js (Js.wrap_callback callback)

let on_context_menu_clicked
    (f : string -> string -> string -> unit) : unit =
  on_context_menu_clicked_js
    (Js.wrap_callback (fun menu_id link_url page_url ->
       f (Js.to_string menu_id) (Js.to_string link_url)
         (Js.to_string page_url)))

let on_installed (f : unit -> unit) : unit =
  on_installed_js (Js.wrap_callback f)

let on_startup (f : unit -> unit) : unit =
  on_startup_js (Js.wrap_callback f)

(* -- URL filtering *)

let is_internal_url (url : string) : bool =
  List.exists
    ~f:(fun prefix -> String.is_prefix url ~prefix)
    [
      "chrome://";
      "chrome-extension://";
      "about:";
      "edge://";
      "brave://";
      "chrome-search://";
      "devtools://";
    ]

(* -- Event types for the coordinator *)

type native_port

type event =
  | Navigation of { url : string }
  | Bridge_message of { raw : string }
  | Port_disconnected
  | Connect_requested
  | Context_menu of { menu_id : string; link_url : string; page_url : string }
  | Popup_query of { json : Yojson.Safe.t; respond : Yojson.Safe.t -> unit }
  | Setup_menus
  | Refresh_menus of { tenants : string list }
  | Delete_rule_at of { index : int }

type state = {
  native_port : native_port option;
  pending_callbacks : (Protocol.Wire.response -> unit) list;
  tenant_names : string list;
}

(* -- Event stream *)

let (event_stream : event Lwt_stream.t), push_event =
  Lwt_stream.create ()

let push ev = push_event (Some ev)

(* -- State operations (pure) *)

let initial_state = { native_port = None; pending_callbacks = []; tenant_names = [] }

let is_connected (state : state) : bool =
  Option.is_some state.native_port

let send_to_bridge (state : state) (json : Yojson.Safe.t)
    (on_response : Protocol.Wire.response -> unit) : state =
  match state.native_port with
  | None ->
    log "No native port connected";
    state
  | Some p ->
    port_post_message_json_js p (Js.string (json_to_string json));
    { state with pending_callbacks = state.pending_callbacks @ [ on_response ] }

let send_command (state : state) (cmd : Protocol.packed_command)
    (on_response : Protocol.Wire.response -> unit) : state =
  let (Protocol.Command c) = cmd in
  let json = Protocol.serialize_command_json c in
  send_to_bridge state json on_response

(* -- Connection management *)

let connect (_state : state) : state =
  match
    let p = connect_native_js () in
    log "Connected to native messaging host";
    port_on_message_json_js p
      (Js.wrap_callback (fun msg ->
         push (Bridge_message { raw = Js.to_string msg })));
    port_on_disconnect_js p
      (Js.wrap_callback (fun () -> push Port_disconnected));
    p
  with
  | p ->
    let brand = Js.to_string (get_browser_brand_js ()) in
    log (Printf.sprintf "Browser brand: %s" brand);
    let state = { native_port = Some p; pending_callbacks = []; tenant_names = [] } in
    let state =
      send_command state (Command (Register brand)) (fun _wire_resp -> ())
    in
    send_command state (Command Get_config) (fun wire_resp ->
        match Protocol.response_of_wire Get_config wire_resp with
        | Ok cfg ->
          push (Refresh_menus { tenants = List.map cfg.tenants ~f:fst })
        | Error msg ->
          log (Printf.sprintf "Config fetch for menus failed: %s" msg))
  | exception exn ->
    log (Printf.sprintf "Failed to connect: %s" (Exn.to_string exn));
    initial_state

(* -- Event handlers (pure state transformers) *)

let handle_bridge_message (state : state) (raw : string) : state =
  match json_of_string raw with
  | Error msg ->
    log (Printf.sprintf "Failed to parse bridge JSON: %s" msg);
    state
  | Ok json ->
    (match Protocol.bridge_message_of_yojson json with
     | Ok (Protocol.Wire.Response wire_resp) ->
       (match state.pending_callbacks with
        | [] ->
          log "Received response with no pending callback";
          state
        | cb :: rest ->
          cb wire_resp;
          { state with pending_callbacks = rest })
     | Ok (Protocol.Wire.Push (Protocol.Wire.Navigate { url })) ->
       log (Printf.sprintf "Received NAVIGATE push: %s" url);
       create_tab url;
       state
     | Error msg ->
       log (Printf.sprintf "Failed to parse bridge message: %s" msg);
       state)

let handle_navigation (state : state) (url : string) : state =
  match is_connected state with
  | false -> state
  | true ->
    (match is_internal_url url with
     | true -> state
     | false ->
       send_command state (Command (Open url)) (fun wire_resp ->
           match Protocol.response_of_wire (Open url) wire_resp with
           | Ok Local -> ()
           | Ok (Remote tid) ->
             log (Printf.sprintf "URL %s routed to remote tenant %s" url tid)
           | Error msg -> log (Printf.sprintf "Open error: %s" msg)))

let handle_context_menu (state : state) (menu_id : string)
    (link_url : string) (page_url : string) : state =
  match String.lsplit2 menu_id ~on:':' with
  | Some ("open_in", target) ->
    (match String.is_empty link_url with
     | true -> state
     | false ->
       send_command state (Command (Open_on (target, link_url)))
         (fun _resp -> ()))
  | Some ("send_to", target) ->
    (match String.is_empty page_url with
     | true -> state
     | false ->
       send_command state (Command (Open_on (target, page_url)))
         (fun _resp -> ()))
  | _ ->
  match menu_id with
  | "add_rule" ->
    let encoded_url =
      page_url |> Js.string |> Js.encodeURIComponent |> Js.to_string
    in
    let dialog_url =
      Printf.sprintf "add_rule.html?url=%s" encoded_url
    in
    create_window_js (Js.string dialog_url);
    state
  | "delete_rule" ->
    let url =
      match String.is_empty page_url with
      | true -> link_url
      | false -> page_url
    in
    (match String.is_empty url with
     | true -> state
     | false ->
       send_command state (Command (Test url)) (fun wire_resp ->
           match Protocol.response_of_wire (Test url) wire_resp with
           | Ok (Match { rule_index; _ }) ->
             push (Delete_rule_at { index = rule_index })
           | Ok (No_match _) ->
             log (Printf.sprintf "No rule matches %s" url)
           | Error msg ->
             log (Printf.sprintf "Test error: %s" msg)))
  | _ -> state

let handle_popup_query (state : state) (json : Yojson.Safe.t)
    (respond : Yojson.Safe.t -> unit) : state =
  let connected = is_connected state in
  match string_field json "action" with
  | Ok "get_status" ->
    respond
      (`Assoc
         [
           ("connected", `Bool connected);
           ( "info",
             `String
               (match connected with
                | true -> "Native messaging host connected"
                | false -> "Not connected to native host") );
         ]);
    state
  | Ok "query_status" ->
    send_command state (Command Status) (fun wire_resp ->
        respond
          (`Assoc
             [
               ("connected", `Bool connected);
               ("data", Protocol.Wire.response_to_yojson wire_resp);
             ]))
  | Ok "query_config" ->
    send_command state (Command Get_config) (fun wire_resp ->
        respond
          (`Assoc
             [
               ("connected", `Bool connected);
               ("data", Protocol.Wire.response_to_yojson wire_resp);
             ]))
  | Ok "reconnect" ->
    let state = connect state in
    respond (`Assoc [ ("connected", `Bool (is_connected state)) ]);
    state
  | Ok "add_rule" ->
    let pattern =
      match string_field json "pattern" with
      | Ok s -> s
      | Error _ -> ""
    in
    let target =
      match string_field json "target" with
      | Ok s -> s
      | Error _ -> ""
    in
    (match String.is_empty pattern || String.is_empty target with
     | true ->
       respond (`Assoc [ ("error", `String "pattern and target required") ]);
       state
     | false ->
       let rule : Protocol.rule =
         { pattern; target; enabled = true }
       in
       send_command state (Command (Add_rule rule)) (fun wire_resp ->
           match Protocol.response_of_wire (Add_rule rule) wire_resp with
           | Ok () -> respond (`Assoc [ ("ok", `Bool true) ])
           | Error msg ->
             respond (`Assoc [ ("error", `String msg) ])))
  | Ok "set_config" ->
    (match Yojson.Safe.Util.member "config" json with
     | `Null ->
       respond (`Assoc [ ("error", `String "config field required") ]);
       state
     | config_json ->
       (match Protocol.config_of_yojson config_json with
        | Error msg ->
          respond (`Assoc [ ("error", `String msg) ]);
          state
        | Ok cfg ->
          send_command state (Command (Set_config cfg)) (fun wire_resp ->
              match Protocol.response_of_wire (Set_config cfg) wire_resp with
              | Ok () ->
                push (Refresh_menus { tenants = List.map cfg.tenants ~f:fst });
                respond (`Assoc [ ("ok", `Bool true) ])
              | Error msg ->
                respond (`Assoc [ ("error", `String msg) ]))))
  | Ok other ->
    log (Printf.sprintf "Unknown popup action: %s" other);
    respond (`Assoc [ ("error", `String "unknown action") ]);
    state
  | Error _ ->
    respond (`Assoc [ ("error", `String "invalid message") ]);
    state

let setup_context_menus (tenants : string list) : unit =
  remove_all_context_menus (fun () ->
    (* Parent menus *)
    create_context_menu "open_in" "Open link in…" [ "link" ];
    create_context_menu "send_to" "Send page to…" [ "page" ];
    (* Tenant submenus for both parents *)
    List.iter tenants ~f:(fun tid ->
      create_child_context_menu
        (Printf.sprintf "open_in:%s" tid) "open_in" tid [ "link" ];
      create_child_context_menu
        (Printf.sprintf "send_to:%s" tid) "send_to" tid [ "page" ]);
    (* Standalone items *)
    create_context_menu "add_rule" "Add routing rule…" [ "page" ];
    create_context_menu "delete_rule" "Delete matching rule" [ "page" ])

let handle_delete_rule_at (state : state) (index : int) : state =
  send_command state (Command (Delete_rule index)) (fun wire_resp ->
      match Protocol.response_of_wire (Delete_rule index) wire_resp with
      | Ok () ->
        log (Printf.sprintf "Deleted rule at index %d" index)
      | Error msg ->
        log (Printf.sprintf "Delete rule error: %s" msg))

let handle_event (state : state) (event : event) : state =
  match event with
  | Navigation { url } -> handle_navigation state url
  | Bridge_message { raw } -> handle_bridge_message state raw
  | Port_disconnected ->
    log "Native port disconnected";
    initial_state
  | Connect_requested -> connect state
  | Context_menu { menu_id; link_url; page_url } ->
    handle_context_menu state menu_id link_url page_url
  | Popup_query { json; respond } -> handle_popup_query state json respond
  | Setup_menus ->
    setup_context_menus state.tenant_names;
    state
  | Refresh_menus { tenants } ->
    setup_context_menus tenants;
    { state with tenant_names = tenants }
  | Delete_rule_at { index } ->
    handle_delete_rule_at state index

(* -- Coordinator loop *)

let rec coordinator (state : state) : unit Lwt.t =
  let%lwt event = Lwt_stream.next event_stream in
  let state = handle_event state event in
  coordinator state

(* -- Chrome event registration *)

let register_chrome_listeners () : unit =
  on_before_navigate (fun url _tab_id frame_id ->
      match frame_id with
      | 0 -> push (Navigation { url })
      | _ -> ());
  on_context_menu_clicked (fun menu_id link_url page_url ->
      push (Context_menu { menu_id; link_url; page_url }));
  on_message_json_js
    (Js.wrap_callback (fun msg_str send_response ->
       match json_of_string (Js.to_string msg_str) with
       | Error _ ->
         send_response
           (Js.string (json_to_string (`Assoc [ ("error", `String "invalid JSON") ])))
       | Ok json ->
         push
           (Popup_query
              { json;
                respond = (fun resp ->
                    send_response (Js.string (json_to_string resp)))
              })));
  on_installed (fun () ->
    log "Extension installed";
    push Setup_menus);
  on_startup (fun () ->
    log "Browser started";
    push Setup_menus)

(* -- Initialization *)

let () =
  log "URL Router extension starting";
  register_chrome_listeners ();
  push Connect_requested;
  Lwt.async (fun () -> coordinator initial_state)
