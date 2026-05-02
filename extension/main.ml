open Base
open Stdio
open Js_of_ocaml

(* Suppress unused open — Stdio is required by convention *)
let () = ignore (print_endline : string -> unit)
let () = ignore (Lwt.return : 'a -> 'a Lwt.t)

(* ── JS primitive externals (bound to chrome_api.js) ─────────────── *)

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

external set_timeout_js : (unit -> unit) Js.callback -> int -> unit
  = "url_router_set_timeout"

(* ── Logging ─────────────────────────────────────────────────────── *)

let log msg = log_js (Js.string msg)

(* ── JSON conversion via strings (no Js.Unsafe) ─────────────────── *)

let json_of_string (s : string) : (Yojson.Safe.t, string) Result.t =
  Protocol.parse_json_string s

let json_to_string (json : Yojson.Safe.t) : string =
  Yojson.Safe.to_string json

(* ── Typed wrappers around Chrome APIs ───────────────────────────── *)

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

let set_timeout (f : unit -> unit) (ms : int) : unit =
  set_timeout_js (Js.wrap_callback f) ms

(* ── State ───────────────────────────────────────────────────────── *)

type native_port

type connection_state = {
  mutable native_port : native_port option;
  mutable connected : bool;
  mutable pending_callbacks : (Yojson.Safe.t -> unit) list;
}

let state =
  { native_port = None; connected = false; pending_callbacks = [] }

(* ── JSON field accessor (protocol's string_field is internal) ──── *)

let string_field (json : Yojson.Safe.t) (key : string) :
    (string, string) Result.t =
  match json with
  | `Assoc pairs ->
    (match List.Assoc.find pairs ~equal:String.equal key with
     | Some (`String s) -> Ok s
     | Some _ -> Error (Printf.sprintf "field %s: expected string" key)
     | None -> Error (Printf.sprintf "missing field: %s" key))
  | _ -> Error "expected JSON object"

(* ── Native messaging ───────────────────────────────────────────── *)

let send_to_bridge (json : Yojson.Safe.t)
    (on_response : Yojson.Safe.t -> unit) : unit =
  match state.native_port with
  | None -> log "No native port connected"
  | Some p ->
    state.pending_callbacks <-
      state.pending_callbacks @ [ on_response ];
    port_post_message_json_js p (Js.string (json_to_string json))

let send_command (cmd : Protocol.packed_command)
    (on_response : Yojson.Safe.t -> unit) : unit =
  let (Protocol.Command c) = cmd in
  let json = Protocol.serialize_command_json c in
  send_to_bridge json on_response

let handle_bridge_message (msg_str : Js.js_string Js.t) : unit =
  let s = Js.to_string msg_str in
  match json_of_string s with
  | Error msg -> log (Printf.sprintf "Failed to parse bridge JSON: %s" msg)
  | Ok json ->
    (match Protocol.bridge_message_of_yojson json with
     | Ok (Protocol.Response data) ->
       (match state.pending_callbacks with
        | [] -> log "Received response with no pending callback"
        | cb :: rest ->
          state.pending_callbacks <- rest;
          cb data)
     | Ok (Protocol.Push (Protocol.Push (Protocol.Navigate url))) ->
       log (Printf.sprintf "Received NAVIGATE push: %s" url);
       create_tab url
     | Error msg ->
       log (Printf.sprintf "Failed to parse bridge message: %s" msg))

(* ── URL filtering ───────────────────────────────────────────────── *)

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

(* ── Navigation interception ─────────────────────────────────────── *)

let handle_navigation (url : string) (_tab_id : int) (frame_id : int)
    : unit =
  (* Only intercept top-level navigations *)
  match frame_id with
  | 0 ->
    (match is_internal_url url with
     | true -> ()
     | false ->
       (match state.connected with
        | false -> ()
        | true ->
          send_command (Command (Open url)) (fun response_json ->
            match
              Protocol.deserialize_response_json (Open url)
                response_json
            with
            | Ok (Ok Local) -> ()
            | Ok (Ok (Remote tid)) ->
              log
                (Printf.sprintf "URL %s routed to remote tenant %s"
                   url tid)
            | Ok (Error msg) ->
              log (Printf.sprintf "Open error: %s" msg)
            | Error msg ->
              log (Printf.sprintf "Protocol error: %s" msg))))
  | _ -> ()

(* ── Context menus ───────────────────────────────────────────────── *)

let setup_context_menus () : unit =
  create_context_menu "open_in_tenant" "Open in tenant..." [ "link" ];
  create_context_menu "send_page_to_tenant" "Send page to tenant..."
    [ "page" ]

let handle_context_menu_click (menu_id : string) (link_url : string)
    (page_url : string) : unit =
  let target = "default" in
  match menu_id with
  | "open_in_tenant" ->
    (match String.is_empty link_url with
     | true -> ()
     | false ->
       send_command
         (Command (Open_on (target, link_url)))
         (fun _resp -> ()))
  | "send_page_to_tenant" ->
    (match String.is_empty page_url with
     | true -> ()
     | false ->
       send_command
         (Command (Open_on (target, page_url)))
         (fun _resp -> ()))
  | _ -> ()

(* ── Popup message handling ──────────────────────────────────────── *)

let send_json_response (send_response : Js.js_string Js.t -> unit)
    (json : Yojson.Safe.t) : unit =
  send_response (Js.string (json_to_string json))

let rec handle_popup_message (msg_str : Js.js_string Js.t)
    (send_response : Js.js_string Js.t -> unit) : unit =
  let send = send_json_response send_response in
  match json_of_string (Js.to_string msg_str) with
  | Error _ -> send (`Assoc [ ("error", `String "invalid JSON") ])
  | Ok json ->
    (match string_field json "action" with
     | Ok "get_status" ->
       send
         (`Assoc
            [
              ("connected", `Bool state.connected);
              ( "info",
                `String
                  (match state.connected with
                   | true -> "Native messaging host connected"
                   | false -> "Not connected to native host") );
            ])
     | Ok "query_status" ->
       send_command (Command Status) (fun data ->
           send
             (`Assoc
                [
                  ("connected", `Bool state.connected);
                  ("data", data);
                ]))
     | Ok "query_config" ->
       send_command (Command Get_config) (fun data ->
           send
             (`Assoc
                [
                  ("connected", `Bool state.connected);
                  ("data", data);
                ]))
     | Ok "reconnect" ->
       connect_to_native ();
       send (`Assoc [ ("connected", `Bool state.connected) ])
     | Ok other ->
       log (Printf.sprintf "Unknown popup action: %s" other);
       send (`Assoc [ ("error", `String "unknown action") ])
     | Error _ ->
       send (`Assoc [ ("error", `String "invalid message") ]))

(* ── Connection management ───────────────────────────────────────── *)

and connect_to_native () : unit =
  (match state.native_port with
   | Some _ -> log "Already connected, reconnecting..."
   | None -> ());
  state.pending_callbacks <- [];
  match
    let p = connect_native_js () in
    state.native_port <- Some p;
    state.connected <- true;
    log "Connected to native messaging host";
    port_on_message_json_js p
      (Js.wrap_callback (fun msg -> handle_bridge_message msg));
    port_on_disconnect_js p
      (Js.wrap_callback (fun () ->
         log "Native port disconnected";
         state.native_port <- None;
         state.connected <- false;
         schedule_reconnect ()));
    ()
  with
  | () -> ()
  | exception exn ->
    log
      (Printf.sprintf "Failed to connect: %s" (Exn.to_string exn));
    state.native_port <- None;
    state.connected <- false;
    schedule_reconnect ()

and schedule_reconnect () : unit =
  log "Scheduling reconnection in 5 seconds...";
  set_timeout (fun () -> connect_to_native ()) 5000

(* ── Initialization ──────────────────────────────────────────────── *)

let init () : unit =
  log "URL Router extension starting";
  connect_to_native ();
  on_before_navigate handle_navigation;
  on_context_menu_clicked handle_context_menu_click;
  on_message_json_js
    (Js.wrap_callback (fun msg_str send_response ->
       handle_popup_message msg_str send_response));
  on_installed (fun () ->
    log "Extension installed";
    setup_context_menus ());
  on_startup (fun () ->
    log "Browser started";
    setup_context_menus ())

let () = init ()

