open Base
open Stdio
open Js_of_ocaml

let () = ignore (print_endline : string -> unit)

(* -- JS externals (bound to page_api.js) -- *)

external send_message_raw :
  Js.js_string Js.t ->
  (Js.js_string Js.t -> Js.js_string Js.t -> unit) Js.callback ->
  unit = "url_router_page_send_message"

external storage_get_raw :
  Js.js_string Js.t ->
  (Js.js_string Js.t -> unit) Js.callback ->
  unit = "url_router_page_storage_get"

external storage_set_raw :
  Js.js_string Js.t ->
  (unit -> unit) Js.callback ->
  unit = "url_router_page_storage_set"

external create_tab_raw :
  Js.js_string Js.t -> unit = "url_router_page_create_tab"

external get_extension_url_raw :
  Js.js_string Js.t -> Js.js_string Js.t = "url_router_page_get_extension_url"

(* -- Chrome API wrappers -- *)

let send_message (msg : Yojson.Safe.t)
    ~(on_response : (Yojson.Safe.t, string) Result.t -> unit) : unit =
  send_message_raw
    (Js.string (Yojson.Safe.to_string msg))
    (Js.wrap_callback (fun err resp_str ->
       let err_s = Js.to_string err in
       match String.is_empty err_s with
       | false -> on_response (Error err_s)
       | true ->
         (match Yojson.Safe.from_string (Js.to_string resp_str) with
          | json -> on_response (Ok json)
          | exception _ -> on_response (Error "invalid JSON response"))))

let storage_get (keys : string list)
    ~(on_result : (string * string) list -> unit) : unit =
  let keys_json = `List (List.map keys ~f:(fun k -> `String k)) in
  storage_get_raw
    (Js.string (Yojson.Safe.to_string keys_json))
    (Js.wrap_callback (fun items_str ->
       match Yojson.Safe.from_string (Js.to_string items_str) with
       | `Assoc pairs ->
         List.filter_map pairs ~f:(fun (k, v) ->
           match v with
           | `String s -> Some (k, s)
           | _ -> None)
         |> on_result
       | _ -> on_result []
       | exception _ -> on_result []))

let storage_set (items : (string * string) list)
    ~(on_done : unit -> unit) : unit =
  let json = `Assoc (List.map items ~f:(fun (k, v) -> (k, `String v))) in
  storage_set_raw
    (Js.string (Yojson.Safe.to_string json))
    (Js.wrap_callback on_done)

let create_tab (url : string) : unit =
  create_tab_raw (Js.string url)

let get_extension_url (path : string) : string =
  Js.to_string (get_extension_url_raw (Js.string path))

let validate_regexp (pattern : string) : (unit, string) Result.t =
  match Regexp.regexp pattern with
  | _ -> Ok ()
  | exception Js_error.Exn e -> Error (Js_error.message e)
  | exception _ -> Error "invalid pattern"

(* -- DOM helpers -- *)

let get_by_id (id : string) : Dom_html.element Js.t =
  Dom_html.getElementById id

let input_by_id (id : string) : Dom_html.inputElement Js.t =
  let el = Dom_html.getElementById id in
  Js.Opt.get (Dom_html.CoerceTo.input el)
    (fun () -> failwith (Printf.sprintf "Element '%s' is not an input" id))

let select_by_id (id : string) : Dom_html.selectElement Js.t =
  let el = Dom_html.getElementById id in
  Js.Opt.get (Dom_html.CoerceTo.select el)
    (fun () -> failwith (Printf.sprintf "Element '%s' is not a select" id))

let set_text (el : Dom_html.element Js.t) (text : string) : unit =
  el##.textContent := Js.some (Js.string text)

let set_html (el : Dom_html.element Js.t) (html : string) : unit =
  el##.innerHTML := Js.string html

let on_click (el : Dom_html.element Js.t) (f : unit -> unit) : unit =
  el##.onclick := Dom_html.handler (fun _ev -> f (); Js._true)

let set_timeout (f : unit -> unit) (ms : int) : unit =
  ignore
    (Dom_html.window##setTimeout
       (Js.wrap_callback f)
       (Js.number_of_float (Float.of_int ms)))

let set_display (el : Dom_html.element Js.t) (value : string) : unit =
  el##.style##.display := Js.string value

let set_class (el : Dom_html.element Js.t) (cls : string) : unit =
  el##.className := Js.string cls

let add_class (el : Dom_html.element Js.t) (cls : string) : unit =
  let current = Js.to_string el##.className in
  match String.is_substring current ~substring:cls with
  | true -> ()
  | false -> el##.className := Js.string (current ^ " " ^ cls)

let remove_class (el : Dom_html.element Js.t) (cls : string) : unit =
  let current = Js.to_string el##.className in
  String.split current ~on:' '
  |> List.filter ~f:(fun c -> not (String.equal c cls))
  |> String.concat ~sep:" "
  |> fun s -> el##.className := Js.string s

let escape_html (s : string) : string =
  String.concat_map s ~f:(fun c ->
    match c with
    | '&' -> "&amp;"
    | '<' -> "&lt;"
    | '>' -> "&gt;"
    | '"' -> "&quot;"
    | '\'' -> "&#39;"
    | c -> String.of_char c)

let escape_regexp (s : string) : string =
  String.concat_map s ~f:(fun c ->
    match c with
    | '.' | '*' | '+' | '?' | '^' | '$'
    | '{' | '}' | '(' | ')' | '|' | '[' | ']' | '\\' ->
      Printf.sprintf "\\%c" c
    | c -> String.of_char c)

let bind_clicks (parent : Dom_html.element Js.t) ~(selector : string)
    ~(attr : string) ~(f : string -> unit) : unit =
  let nodes = parent##querySelectorAll (Js.string selector) in
  let len = nodes##.length in
  List.init len ~f:(fun i ->
    Js.Opt.get (nodes##item i) (fun () -> assert false))
  |> List.iter ~f:(fun btn ->
    (btn :> Dom_html.element Js.t)##.onclick :=
      Dom_html.handler (fun _ev ->
        let v =
          Js.Opt.case
            ((btn :> Dom.element Js.t)##getAttribute (Js.string attr))
            (fun () -> "")
            Js.to_string
        in
        f v;
        Js._true))

let get_search_param (key : string) : string option =
  let search = Js.to_string Dom_html.window##.location##.search in
  match String.is_prefix search ~prefix:"?" with
  | false -> None
  | true ->
    String.drop_prefix search 1
    |> String.split ~on:'&'
    |> List.find_map ~f:(fun param ->
      match String.lsplit2 param ~on:'=' with
      | Some (k, v) when String.equal k key ->
        Some (Js.to_string (Js.decodeURIComponent (Js.string v)))
      | _ -> None)

let url_origin (url_str : string) : string option =
  match String.substr_index url_str ~pattern:"://" with
  | None -> None
  | Some scheme_end ->
    let after_scheme = scheme_end + 3 in
    let path_start =
      match String.substr_index url_str ~pattern:"/" ~pos:after_scheme with
      | Some i -> i
      | None -> String.length url_str
    in
    Some (String.prefix url_str path_start)

let create_option (doc : Dom_html.document Js.t) ~(value : string)
    ~(text : string) ~(selected : bool) : Dom_html.optionElement Js.t =
  let opt = Dom_html.createOption doc in
  opt##.value := Js.string value;
  opt##.textContent := Js.some (Js.string text);
  opt##.selected := Js.bool selected;
  opt
