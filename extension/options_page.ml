open! Base
open! Stdio
open Js_of_ocaml

(* -- DOM elements -- *)

let name_input = Page_util.input_by_id "tenantName"
let socket_input = Page_util.input_by_id "socketPath"
let debug_input = Page_util.input_by_id "debugLogging"
let status_msg = Page_util.get_by_id "statusMsg"

(* -- Load saved values -- *)

let () =
  Page_util.storage_get [ "tenant_name"; "socket_path"; "debug_logging" ]
    ~on_result:(fun items ->
      List.iter items ~f:(fun (k, v) ->
        match k with
        | "tenant_name" -> name_input##.value := Js.string v
        | "socket_path" -> socket_input##.value := Js.string v
        | "debug_logging" -> debug_input##.checked := Js.bool (String.equal v "true")
        | _ -> ()))

(* -- Helpers -- *)

let show_status text is_error =
  Page_util.set_text status_msg text;
  Page_util.set_class status_msg
    (match is_error with
     | true -> "msg error"
     | false -> "msg success");
  Page_util.set_timeout
    (fun () -> Page_util.set_text status_msg "")
    2500

(* -- Save button -- *)

let () =
  Page_util.on_click (Page_util.get_by_id "btnSave") (fun () ->
    let name = Js.to_string name_input##.value |> String.strip in
    let socket = Js.to_string socket_input##.value |> String.strip in
    let debug_on = Js.to_bool debug_input##.checked in
    Page_util.storage_set
      [ ("tenant_name", name);
        ("socket_path", socket);
        ("debug_logging", match debug_on with true -> "true" | false -> "false") ]
      ~on_done:(fun () ->
        show_status
          "Saved — reconnect the bridge for changes to take effect."
          false))

(* -- Close button -- *)

let () =
  Page_util.on_click (Page_util.get_by_id "btnClose") (fun () ->
    Dom_html.window##close)
