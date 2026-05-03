open! Base
open! Stdio
open Js_of_ocaml

(* -- DOM elements -- *)

let pattern_input = Page_util.input_by_id "pattern"
let tenant_select = Page_util.select_by_id "tenant"
let error_div = Page_util.get_by_id "error"

(* -- Pre-fill pattern from URL params (set by context menu) -- *)

let () =
  match Page_util.get_search_param "url" with
  | None -> ()
  | Some url ->
    let origin = Page_util.url_origin url in
    (match origin with
     | Some o ->
       let pattern =
         Page_util.escape_regexp o ^ "/.*"
         |> String.substr_replace_first ~pattern:"https:" ~with_:"https?:"
         |> String.substr_replace_first ~pattern:"http:" ~with_:"https?:"
       in
       pattern_input##.value := Js.string pattern
     | None -> ())

(* -- Fetch tenants from config -- *)

let () =
  Page_util.send_message
    (`Assoc [ ("action", `String "query_config") ])
    ~on_response:(fun result ->
      match result with
      | Error _ | Ok `Null ->
        Page_util.set_html
          (tenant_select :> Dom_html.element Js.t)
          {|<option value="">Failed to load</option>|}
      | Ok json ->
        let data =
          match json with
          | `Assoc pairs ->
            (match List.Assoc.find pairs ~equal:String.equal "data" with
             | Some v -> v
             | None -> `Null)
          | _ -> `Null
        in
        (* Wire format: ["Ok_config", { tenants: ... }] *)
        let config =
          match data with
          | `List [ `String "Ok_config"; payload ] -> Some payload
          | _ -> None
        in
        let tenants =
          match config with
          | Some (`Assoc pairs) ->
            (match List.Assoc.find pairs ~equal:String.equal "tenants" with
             | Some (`Assoc ts) -> ts
             | _ -> [])
          | _ -> []
        in
        (match List.is_empty tenants with
         | true ->
           Page_util.set_html
             (tenant_select :> Dom_html.element Js.t)
             {|<option value="">No tenants</option>|}
         | false ->
           Page_util.set_html (tenant_select :> Dom_html.element Js.t) "";
           let doc = Dom_html.document in
           List.iter tenants ~f:(fun (name, info) ->
             let label =
               match info with
               | `Assoc pairs ->
                 (match List.Assoc.find pairs ~equal:String.equal "label" with
                  | Some (`String s) -> s
                  | _ -> name)
               | _ -> name
             in
             let opt =
               Page_util.create_option doc ~value:name ~text:label
                 ~selected:false
             in
             Dom.appendChild tenant_select opt)))

(* -- Cancel button -- *)

let () =
  Page_util.on_click (Page_util.get_by_id "btnCancel") (fun () ->
    Dom_html.window##close)

(* -- Save button -- *)

let () =
  Page_util.on_click (Page_util.get_by_id "btnSave") (fun () ->
    let pattern = Js.to_string pattern_input##.value |> String.strip in
    let tenant = Js.to_string tenant_select##.value in
    Page_util.set_text error_div "";

    match String.is_empty pattern with
    | true -> Page_util.set_text error_div "Pattern is required."
    | false ->
      (match String.is_empty tenant with
       | true -> Page_util.set_text error_div "Select a tenant."
       | false ->
         (match Page_util.validate_regexp pattern with
          | Error msg ->
            Page_util.set_text error_div
              (Printf.sprintf "Invalid regex: %s" msg)
          | Ok () ->
            Page_util.send_message
              (`Assoc
                 [
                   ("action", `String "add_rule");
                   ("pattern", `String pattern);
                   ("target", `String tenant);
                 ])
              ~on_response:(fun result ->
                match result with
                | Error msg ->
                  Page_util.set_text error_div
                    (Printf.sprintf "Error: %s" msg)
                | Ok json ->
                  (match json with
                   | `Assoc pairs ->
                     (match
                        List.Assoc.find pairs ~equal:String.equal "error"
                      with
                      | Some (`String msg) ->
                        Page_util.set_text error_div
                          (Printf.sprintf "Error: %s" msg)
                      | _ -> Dom_html.window##close)
                   | _ -> Dom_html.window##close)))))
