open! Base
open! Stdio
open Js_of_ocaml

let log = Chrome_api.log

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

let create_tab = Chrome_api.Tabs.create_url
let on_before_navigate = Chrome_api.Web_navigation.on_before_navigate
let create_context_menu = Chrome_api.Context_menus.create
let create_child_context_menu = Chrome_api.Context_menus.create_child
let remove_all_context_menus = Chrome_api.Context_menus.remove_all
let on_context_menu_clicked = Chrome_api.Context_menus.on_clicked
let on_installed = Chrome_api.Runtime.on_installed
let on_startup = Chrome_api.Runtime.on_startup

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

type native_port = Chrome_api.port

type event =
  | Navigation of { url : string; tab_id : int }
  | Bridge_message of { raw : string }
  | Port_disconnected
  | Connect_requested
  | Connect_with_settings of { port : native_port; tenant_name : string; daemon_host : string; daemon_port : string; debug_logging : bool }
  | Context_menu of { menu_id : string; link_url : string; page_url : string; tab_id : int option }
  | Popup_query of { json : Yojson.Safe.t; respond : Yojson.Safe.t -> unit }
  | Setup_menus
  | Refresh_menus of { tenants : string list }
  | Self_registered of { tenant_id : string }
  | Delete_rule_at of { index : int }

type state = {
  native_port : native_port option;
  pending_callbacks : (Protocol.Wire.response -> unit) list;
  tenant_names : string list;
  self_tenant_id : string option;
  debug_logging : bool;
}

(* -- Event stream *)

let (event_stream : event Lwt_stream.t), push_event =
  Lwt_stream.create ()

let push ev = push_event (Some ev)

(* -- State operations (pure) *)

let initial_state = { native_port = None; pending_callbacks = []; tenant_names = []; self_tenant_id = None; debug_logging = false }

let debug (state : state) (msg : string) : unit =
  match state.debug_logging with
  | true -> log msg
  | false -> ()

let is_connected (state : state) : bool =
  Option.is_some state.native_port

let update_badge (connected : bool) : unit =
  match connected with
  | true ->
    Chrome_api.Action.set_icon
      "icons/icon16_connected.png"
      "icons/icon48_connected.png"
      "icons/icon128_connected.png"
  | false ->
    Chrome_api.Action.set_icon
      "icons/icon16_disconnected.png"
      "icons/icon48_disconnected.png"
      "icons/icon128_disconnected.png"

let send_to_bridge (state : state) (json : Yojson.Safe.t)
    (on_response : Protocol.Wire.response -> unit) : state =
  match state.native_port with
  | None ->
    log "No native port connected";
    state
  | Some p ->
    Chrome_api.Port.post_message_json p (json_to_string json);
    { state with pending_callbacks = state.pending_callbacks @ [ on_response ] }

let send_command (state : state) (cmd : Protocol.packed_command)
    (on_response : Protocol.Wire.response -> unit) : state =
  let (Protocol.Command c) = cmd in
  let json = Protocol.serialize_command_json c in
  send_to_bridge state json on_response

(* -- Connection management *)

let non_empty (s : string) : string option =
  match String.is_empty s with
  | true -> None
  | false -> Some s

let connect_with_settings (port : native_port) (tenant_name : string) (daemon_host : string) (daemon_port : string) ~(debug_logging : bool) : state =
  let brand = non_empty (Chrome_api.Navigator.get_browser_brand ()) in
  let name = non_empty tenant_name in
  let address =
    let h = Option.value (non_empty daemon_host) ~default:"127.0.0.1" in
    let p = Option.value (non_empty daemon_port) ~default:(Int.to_string Protocol.default_port) in
    Some (Printf.sprintf "%s:%s" h p)
  in
  log (Printf.sprintf "Browser brand: %s, tenant: %s, address: %s"
    (Option.value brand ~default:"(none)")
    (Option.value name ~default:"(default)")
    (Option.value address ~default:"(default)"));
  let state = { native_port = Some port; pending_callbacks = []; tenant_names = []; self_tenant_id = None; debug_logging } in
  let register_wire : Protocol.Wire.command =
    Register { brand; address; name }
  in
  let json = Protocol.Wire.command_to_yojson register_wire in
  let state = send_to_bridge state json (fun wire_resp ->
    match wire_resp with
    | Protocol.Wire.Ok_registered { tenant_id } ->
      push (Self_registered { tenant_id })
    | _ -> ()) in
  send_command state (Command Get_config) (fun wire_resp ->
      match Protocol.response_of_wire Get_config wire_resp with
      | Ok cfg ->
        push (Refresh_menus { tenants = List.map cfg.tenants ~f:fst })
      | Error msg ->
        log (Printf.sprintf "Config fetch for menus failed: %s" msg))

let connect (_state : state) : state =
  match
    let p = Chrome_api.Runtime.connect_native "alloy" in
    log "Connected to native messaging host";
    Chrome_api.Port.on_message_json p (fun msg ->
      push (Bridge_message { raw = msg }));
    Chrome_api.Port.on_disconnect p (fun () -> push Port_disconnected);
    p
  with
  | p ->
    Chrome_api.Storage.get_local [ "tenant_name"; "daemon_host"; "daemon_port"; "debug_logging" ]
      ~on_result:(fun pairs ->
        let find k =
          List.Assoc.find pairs ~equal:String.equal k
          |> Option.value ~default:""
        in
        push
          (Connect_with_settings
             {
               port = p;
               tenant_name = find "tenant_name";
               daemon_host = find "daemon_host";
               daemon_port = find "daemon_port";
               debug_logging = String.equal (find "debug_logging") "true";
             }));
    { native_port = Some p; pending_callbacks = []; tenant_names = []; self_tenant_id = None; debug_logging = false }
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
     | Ok (Protocol.Wire.Push (Protocol.Wire.Registered { tenant_id })) ->
       log (Printf.sprintf "Re-registered as tenant: %s" tenant_id);
       push (Self_registered { tenant_id });
       state
     | Error msg ->
       log (Printf.sprintf "Failed to parse bridge message: %s" msg);
       state)

let handle_navigation (state : state) (url : string) (tab_id : int) : state =
  match is_connected state with
  | false -> state
  | true ->
    (match is_internal_url url with
     | true -> state
     | false ->
       let t0 = Chrome_api.performance_now () in
       debug state (Printf.sprintf "→ Open %s" url);
       send_command state (Command (Open url)) (fun wire_resp ->
           let elapsed = Chrome_api.performance_now () -. t0 in
           match Protocol.response_of_wire (Open url) wire_resp with
           | Ok Local ->
             debug state (Printf.sprintf "← Local (%.1f ms) %s" elapsed url)
           | Ok (Remote tid) ->
             debug state (Printf.sprintf "← Remote %s (%.1f ms) %s" tid elapsed url);
             Chrome_api.Tabs.remove tab_id
           | Error msg -> log (Printf.sprintf "Open error: %s" msg)))

let handle_context_menu (state : state) (menu_id : string)
    (link_url : string) (page_url : string) (tab_id : int option) : state =
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
         (fun _resp -> Option.iter tab_id ~f:Chrome_api.Tabs.remove))
  | _ ->
  match menu_id with
  | "add_rule" ->
    let encoded_url =
      page_url |> Js.string |> Js.encodeURIComponent |> Js.to_string
    in
    let dialog_url =
      Printf.sprintf "add_rule.html?url=%s" encoded_url
    in
    Chrome_api.Windows.create_popup ~url:dialog_url ~width:420 ~height:300;
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
    (match connected with
     | false ->
       respond (`Assoc [ ("connected", `Bool false) ]);
       state
     | true ->
       send_command state (Command Status) (fun wire_resp ->
           match Protocol.response_of_wire Status wire_resp with
           | Ok info ->
             respond (`Assoc [ ("connected", `Bool true);
                               ("registered_tenants", `List (List.map info.registered_tenants ~f:(fun s -> `String s))) ])
           | Error msg ->
             respond (`Assoc [ ("connected", `Bool false); ("error", `String msg) ])))
  | Ok "query_tenants" ->
    (match connected with
     | false ->
       respond (`Assoc [ ("registered_tenants", `List []); ("tenants", `Assoc []) ]);
       state
     | true ->
       let status_ref = ref None in
       let config_ref = ref None in
       let pending = ref 2 in
       let try_respond () =
         match !pending > 0 with
         | true -> ()
         | false ->
           let registered =
             match !status_ref with
             | Some info -> info.Protocol.registered_tenants
             | None -> []
           in
           let tenants =
             match !config_ref with
             | Some cfg -> cfg.Protocol.tenants
             | None -> []
            in
            let self = Option.value state.self_tenant_id ~default:"" in
            respond (`Assoc [
              ("self_tenant_id", `String self);
              ("registered_tenants", `List (List.map registered ~f:(fun s -> `String s)));
              ("tenants", `Assoc (List.map tenants ~f:(fun (id, tc) ->
                (id, `Assoc [
                  ("label", `String tc.Protocol.label);
                  ("brand", match tc.brand with Some b -> `String b | None -> `Null);
                ]))))
            ])
       in
       let state = send_command state (Command Status) (fun wire_resp ->
           (match Protocol.response_of_wire Status wire_resp with
            | Ok info -> status_ref := Some info
            | Error _ -> ());
           pending := !pending - 1;
           try_respond ())
       in
       send_command state (Command Get_config) (fun wire_resp ->
           (match Protocol.response_of_wire Get_config wire_resp with
            | Ok cfg -> config_ref := Some cfg
            | Error _ -> ());
           pending := !pending - 1;
           try_respond ()))
  | Ok "send_to" ->
    let target =
      match string_field json "target" with
      | Ok s -> s
      | Error _ -> ""
    in
    let url =
      match string_field json "url" with
      | Ok s -> s
      | Error _ -> ""
    in
    (match String.is_empty target || String.is_empty url with
     | true ->
       respond (`Assoc [ ("error", `String "target and url required") ]);
       state
     | false ->
       send_command state (Command (Open_on (target, url))) (fun wire_resp ->
           match Protocol.response_of_wire (Open_on (target, url)) wire_resp with
           | Ok _ -> respond (`Assoc [ ("ok", `Bool true) ])
           | Error msg -> respond (`Assoc [ ("error", `String msg) ])))
  | Ok "delete_matching_rule" ->
    let url =
      match string_field json "url" with
      | Ok s -> s
      | Error _ -> ""
    in
    (match String.is_empty url with
     | true ->
       respond (`Assoc [ ("error", `String "url required") ]);
       state
     | false ->
       send_command state (Command (Test url)) (fun wire_resp ->
           match Protocol.response_of_wire (Test url) wire_resp with
           | Ok (Match { rule_index; _ }) ->
             push (Delete_rule_at { index = rule_index });
             respond (`Assoc [ ("ok", `Bool true) ])
           | Ok (No_match _) ->
             respond (`Assoc [ ("error", `String "No matching rule") ])
           | Error msg ->
             respond (`Assoc [ ("error", `String msg) ])))
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
    create_context_menu ~id:"open_in" ~title:"Open link in" ~contexts:[ "link" ];
    create_context_menu ~id:"send_to" ~title:"Send page" ~contexts:[ "page" ];
    List.iter tenants ~f:(fun tid ->
      create_child_context_menu
        ~id:(Printf.sprintf "open_in:%s" tid) ~parent_id:"open_in"
        ~title:tid ~contexts:[ "link" ];
      create_child_context_menu
        ~id:(Printf.sprintf "send_to:%s" tid) ~parent_id:"send_to"
        ~title:tid ~contexts:[ "page" ]);
    create_context_menu ~id:"add_rule" ~title:"Add rule" ~contexts:[ "page" ];
    create_context_menu ~id:"delete_rule" ~title:"Delete matching rule" ~contexts:[ "page" ])

let handle_delete_rule_at (state : state) (index : int) : state =
  send_command state (Command (Delete_rule index)) (fun wire_resp ->
      match Protocol.response_of_wire (Delete_rule index) wire_resp with
      | Ok () ->
        log (Printf.sprintf "Deleted rule at index %d" index)
      | Error msg ->
        log (Printf.sprintf "Delete rule error: %s" msg))

let handle_event (state : state) (event : event) : state =
  match event with
  | Navigation { url; tab_id } -> handle_navigation state url tab_id
  | Bridge_message { raw } -> handle_bridge_message state raw
  | Port_disconnected ->
    log "Native port disconnected, reconnecting in 2s…";
    Chrome_api.set_timeout (fun () -> push Connect_requested) 2000;
    { initial_state with debug_logging = state.debug_logging }
  | Connect_requested -> connect state
  | Connect_with_settings { port; tenant_name; daemon_host; daemon_port; debug_logging } ->
    connect_with_settings port tenant_name daemon_host daemon_port ~debug_logging
  | Context_menu { menu_id; link_url; page_url; tab_id } ->
    handle_context_menu state menu_id link_url page_url tab_id
  | Popup_query { json; respond } -> handle_popup_query state json respond
  | Setup_menus ->
    setup_context_menus state.tenant_names;
    state
  | Refresh_menus { tenants } ->
    setup_context_menus tenants;
    { state with tenant_names = tenants }
  | Self_registered { tenant_id } ->
    log (Printf.sprintf "Registered as tenant: %s" tenant_id);
    { state with self_tenant_id = Some tenant_id }
  | Delete_rule_at { index } ->
    handle_delete_rule_at state index

(* -- Coordinator loop *)

let rec coordinator (state : state) : unit Lwt.t =
  let%lwt event = Lwt_stream.next event_stream in
  let state = handle_event state event in
  update_badge (Option.is_some state.self_tenant_id);
  coordinator state

(* -- Chrome event registration *)

let register_chrome_listeners () : unit =
  on_before_navigate (fun url tab_id frame_id ->
      match frame_id with
      | 0 -> push (Navigation { url; tab_id })
      | _ -> ());
  on_context_menu_clicked (fun menu_id link_url page_url tab_id ->
      push (Context_menu { menu_id; link_url; page_url; tab_id }));
  Chrome_api.Runtime.on_message (fun msg_str respond ->
     match json_of_string msg_str with
     | Error _ ->
       respond (json_to_string (`Assoc [ ("error", `String "invalid JSON") ]))
     | Ok json ->
       push
         (Popup_query
            { json;
              respond = (fun resp -> respond (json_to_string resp))
            }));
  on_installed (fun () ->
    log "Extension installed";
    push Setup_menus);
  on_startup (fun () ->
    log "Browser started";
    push Setup_menus)

(* -- Initialization *)

let () =
  log "Alloy extension starting";
  update_badge false;
  register_chrome_listeners ();
  push Connect_requested;
  Lwt.async (fun () -> coordinator initial_state)
