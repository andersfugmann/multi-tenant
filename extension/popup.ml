open! Base
open! Stdio
open Js_of_ocaml

(* -- DOM elements -- *)

let status_dot = Page_util.get_by_id "statusDot"
let status_text = Page_util.get_by_id "statusText"
let status_panel = Page_util.get_by_id "statusPanel"
let uptime_el = Page_util.get_by_id "uptime"
let tenant_list = Page_util.get_by_id "tenantList"

(* -- Helpers -- *)

let set_status (connected : bool) (text : string) : unit =
  Page_util.set_class status_dot
    (match connected with
     | true -> "dot connected"
     | false -> "dot disconnected");
  Page_util.set_text status_text text

let format_uptime (seconds : int) : string =
  let h = seconds / 3600 in
  let m = (seconds % 3600) / 60 in
  let s = seconds % 60 in
  (match h > 0 with true -> [ Printf.sprintf "%dh" h ] | false -> [])
  @ (match m > 0 with true -> [ Printf.sprintf "%dm" m ] | false -> [])
  @ [ Printf.sprintf "%ds" s ]
  |> String.concat ~sep:" "

(* -- Yojson helpers -- *)

let member key = function
  | `Assoc pairs ->
    (match List.Assoc.find pairs ~equal:String.equal key with
     | Some v -> v
     | None -> `Null)
  | _ -> `Null

let to_bool = function `Bool b -> b | _ -> false
let to_int = function `Int i -> i | _ -> 0
let to_string_j = function `String s -> s | _ -> ""

let to_string_list = function
  | `List items -> List.filter_map items ~f:(function `String s -> Some s | _ -> None)
  | _ -> []

(* -- Initial status check -- *)

let () =
  Page_util.send_message
    (`Assoc [ ("action", `String "get_status") ])
    ~on_response:(fun result ->
      match result with
      | Error _ -> set_status false "Not connected"
      | Ok json ->
        let connected = member "connected" json |> to_bool in
        set_status connected
          (match connected with
           | true -> "Connected"
           | false -> "Disconnected"))

(* -- View status button -- *)

let () =
  Page_util.on_click (Page_util.get_by_id "btnStatus") (fun () ->
    let pending = ref 2 in
    let status_data = ref None in
    let config_data = ref None in

    let render () =
      match !pending > 0 with
      | true -> ()
      | false ->
        Page_util.set_display status_panel "block";
        Page_util.set_html tenant_list "";

        (* Uptime *)
        let uptime_text =
          match !status_data with
          | Some json ->
            let s = member "uptime_seconds" json |> to_int in
            (match s > 0 with
             | true -> Printf.sprintf "Daemon uptime: %s" (format_uptime s)
             | false -> "")
          | None -> ""
        in
        Page_util.set_text uptime_el uptime_text;

        (* Connected tenant set *)
        let connected_set =
          match !status_data with
          | Some json ->
            member "registered_tenants" json
            |> to_string_list
            |> Set.of_list (module String)
          | None -> Set.empty (module String)
        in

        (* Tenants from config *)
        let config_tenants =
          match !config_data with
          | Some json ->
            (match member "tenants" json with
             | `Assoc pairs ->
               List.map pairs ~f:(fun (id, info) ->
                 let label = member "label" info |> to_string_j in
                 let brand = member "brand" info |> to_string_j in
                 (id, label, brand, Set.mem connected_set id))
             | _ -> [])
          | None -> []
        in

        (* Add connected tenants not in config *)
        let config_ids =
          List.map config_tenants ~f:(fun (id, _, _, _) -> id)
          |> Set.of_list (module String)
        in
        let extra =
          Set.diff connected_set config_ids
          |> Set.to_list
          |> List.map ~f:(fun id -> (id, "", "", true))
        in

        let all_tenants =
          config_tenants @ extra
          |> List.sort ~compare:(fun (a, _, _, _) (b, _, _, _) ->
            String.compare a b)
        in

        (match List.is_empty all_tenants with
         | true ->
           Page_util.set_html tenant_list
             {|<li style="color:#5f6368">No tenants</li>|}
         | false ->
           let doc = Dom_html.document in
           List.iter all_tenants ~f:(fun (id, label, brand, is_connected) ->
             let li = Dom_html.createLi doc in

             let dot = Dom_html.createSpan doc in
             Page_util.set_class (dot :> Dom_html.element Js.t)
               (match is_connected with
                | true -> "dot connected"
                | false -> "dot disconnected");
             Dom.appendChild li dot;

             let name_span = Dom_html.createSpan doc in
             Page_util.set_class (name_span :> Dom_html.element Js.t) "tenant-name";
             Page_util.set_text (name_span :> Dom_html.element Js.t) id;
             Dom.appendChild li name_span;

             let detail =
               match String.is_empty label with
               | true -> brand
               | false -> label
             in
             (match String.is_empty detail with
              | true -> ()
              | false ->
                let lbl = Dom_html.createSpan doc in
                Page_util.set_class (lbl :> Dom_html.element Js.t) "tenant-label";
                Page_util.set_text (lbl :> Dom_html.element Js.t) detail;
                Dom.appendChild li lbl);

             Dom.appendChild tenant_list li))
    in

    Page_util.send_message
      (`Assoc [ ("action", `String "query_status") ])
      ~on_response:(fun result ->
        (match result with
         | Ok json ->
           (match member "data" json with
            | `List [ `String "Ok_status"; payload ] ->
              status_data := Some payload
            | _ -> ())
         | Error _ -> ());
        pending := !pending - 1;
        render ());

    Page_util.send_message
      (`Assoc [ ("action", `String "query_config") ])
      ~on_response:(fun result ->
        (match result with
         | Ok json ->
           (match member "data" json with
            | `List [ `String "Ok_config"; payload ] ->
              config_data := Some payload
            | _ -> ())
         | Error _ -> ());
        pending := !pending - 1;
        render ()))

(* -- Configure button -- *)

let () =
  Page_util.on_click (Page_util.get_by_id "btnConfig") (fun () ->
    Page_util.create_tab (Page_util.get_extension_url "config.html");
    Dom_html.window##close)

(* -- Reconnect button -- *)

let () =
  Page_util.on_click (Page_util.get_by_id "btnReconnect") (fun () ->
    Page_util.send_message
      (`Assoc [ ("action", `String "reconnect") ])
      ~on_response:(fun result ->
        match result with
        | Error _ -> set_status false "Error reconnecting"
        | Ok json ->
          let connected = member "connected" json |> to_bool in
          set_status connected
            (match connected with
             | true -> "Connected"
             | false -> "Disconnected")))
