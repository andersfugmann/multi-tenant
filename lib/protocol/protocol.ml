open Base
open Stdio

(* ── Core data types ─────────────────────────────────────────────── *)

type tenant_id = string [@@deriving yojson]
type url = string [@@deriving yojson]

type rule = {
  pattern : string;
  target : tenant_id;
  enabled : bool;
}
[@@deriving yojson]

type tenant_config = {
  browser_cmd : string;
  label : string;
  color : string;
}
[@@deriving yojson]

type defaults = {
  unmatched : string;
  cooldown_seconds : int;
  browser_launch_timeout : int;
}
[@@deriving yojson]

(* Custom yojson for (string * tenant_config) list as a JSON object *)
let tenants_to_yojson (lst : (string * tenant_config) list) : Yojson.Safe.t =
  `Assoc
    (List.map lst ~f:(fun (k, v) -> (k, tenant_config_to_yojson v)))

let tenants_of_yojson (json : Yojson.Safe.t) :
    ((string * tenant_config) list, string) Result.t =
  match json with
  | `Assoc pairs ->
    List.fold_result pairs ~init:[] ~f:(fun acc (k, v) ->
        tenant_config_of_yojson v |> Result.map ~f:(fun tc -> (k, tc) :: acc))
    |> Result.map ~f:List.rev
  | _ -> Error "tenants: expected JSON object"

type config = {
  socket : string;
  tenants : (string * tenant_config) list;
      [@to_yojson tenants_to_yojson] [@of_yojson tenants_of_yojson]
  rules : rule list;
  defaults : defaults;
}
[@@deriving yojson]

type status_info = {
  registered_tenants : tenant_id list;
  uptime_seconds : int;
}
[@@deriving yojson]

(* ── Response payload types ──────────────────────────────────────── *)

type route_result =
  | Local
  | Remote of tenant_id
[@@deriving yojson]

type test_result =
  | Match of { tenant : tenant_id; rule_index : int }
  | No_match of { default_tenant : tenant_id }
[@@deriving yojson]

(* ── GADT command type ───────────────────────────────────────────── *)

type _ command =
  | Register : unit command
  | Open : url -> route_result command
  | Open_on : tenant_id * url -> route_result command
  | Test : url -> test_result command
  | Get_config : config command
  | Set_config : config -> unit command
  | Add_rule : rule -> unit command
  | Update_rule : int * rule -> unit command
  | Delete_rule : int -> unit command
  | Status : status_info command

(* ── Type-safe response ──────────────────────────────────────────── *)

type 'a response = ('a, string) Result.t

(* ── Server push ─────────────────────────────────────────────────── *)

type _ server_push = Navigate : url -> url server_push

type packed_server_push = Push : 'a server_push -> packed_server_push

(* ── Existential wrappers ────────────────────────────────────────── *)

type packed_command = Command : 'a command -> packed_command

type 'a server_command = { tenant : tenant_id; command : 'a command }

type packed_server_command =
  | Server_command : 'a server_command -> packed_server_command

(* ── Helpers ─────────────────────────────────────────────────────── *)

let words_n (s : string) (n : int) : (string list, string) Result.t =
  let parts = String.split s ~on:' ' in
  match Int.( >= ) (List.length parts) n with
  | true ->
    let front = List.take parts (n - 1) in
    let rest =
      List.drop parts (n - 1)
      |> String.concat ~sep:" "
    in
    Ok (front @ [ rest ])
  | false -> Error (Printf.sprintf "expected at least %d fields" n)

let parse_json_string (s : string) : (Yojson.Safe.t, string) Result.t =
  match Yojson.Safe.from_string s with
  | json -> Ok json
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)

(* ── Line protocol: server commands ──────────────────────────────── *)

let serialize_server_command : type a. a server_command -> string =
 fun { tenant; command } ->
  match command with
  | Register -> Printf.sprintf "REGISTER %s" tenant
  | Open url -> Printf.sprintf "OPEN %s %s" tenant url
  | Open_on (target, url) ->
    Printf.sprintf "OPEN-ON %s %s %s" tenant target url
  | Test url -> Printf.sprintf "TEST %s %s" tenant url
  | Get_config -> Printf.sprintf "GET-CONFIG %s" tenant
  | Set_config cfg ->
    Printf.sprintf "SET-CONFIG %s %s" tenant
      (config_to_yojson cfg |> Yojson.Safe.to_string)
  | Add_rule r ->
    Printf.sprintf "ADD-RULE %s %s" tenant
      (rule_to_yojson r |> Yojson.Safe.to_string)
  | Update_rule (idx, r) ->
    Printf.sprintf "UPDATE-RULE %s %d %s" tenant idx
      (rule_to_yojson r |> Yojson.Safe.to_string)
  | Delete_rule idx -> Printf.sprintf "DELETE-RULE %s %d" tenant idx
  | Status -> Printf.sprintf "STATUS %s" tenant

let deserialize_server_command (line : string) :
    (packed_server_command, string) Result.t =
  match words_n line 2 with
  | Error e -> Error e
  | Ok parts ->
    let keyword = List.hd_exn parts in
    let rest = List.nth_exn parts 1 in
    (match keyword with
     | "REGISTER" ->
       Ok (Server_command { tenant = rest; command = Register })
     | "STATUS" ->
       Ok (Server_command { tenant = rest; command = Status })
     | "GET-CONFIG" ->
       Ok (Server_command { tenant = rest; command = Get_config })
     | "OPEN" ->
       (match words_n rest 2 with
        | Error e -> Error e
        | Ok [ tenant; url ] ->
          Ok (Server_command { tenant; command = Open url })
        | Ok _ -> Error "OPEN: parse error")
     | "TEST" ->
       (match words_n rest 2 with
        | Error e -> Error e
        | Ok [ tenant; url ] ->
          Ok (Server_command { tenant; command = Test url })
        | Ok _ -> Error "TEST: parse error")
     | "OPEN-ON" ->
       (match words_n rest 3 with
        | Error e -> Error e
        | Ok [ tenant; target; url ] ->
          Ok (Server_command { tenant; command = Open_on (target, url) })
        | Ok _ -> Error "OPEN-ON: parse error")
     | "SET-CONFIG" ->
       Result.bind (words_n rest 2) ~f:(function
         | [ tenant; json_str ] ->
           Result.bind (parse_json_string json_str) ~f:(fun json ->
               Result.bind (config_of_yojson json) ~f:(fun cfg ->
                   Ok (Server_command { tenant; command = Set_config cfg })))
         | _ -> Error "SET-CONFIG: parse error")
     | "ADD-RULE" ->
       Result.bind (words_n rest 2) ~f:(function
         | [ tenant; json_str ] ->
           Result.bind (parse_json_string json_str) ~f:(fun json ->
               Result.bind (rule_of_yojson json) ~f:(fun r ->
                   Ok (Server_command { tenant; command = Add_rule r })))
         | _ -> Error "ADD-RULE: parse error")
     | "UPDATE-RULE" ->
       Result.bind (words_n rest 3) ~f:(function
         | [ tenant; idx_str; json_str ] ->
           Result.bind
             (Int.of_string_opt idx_str
              |> Result.of_option ~error:"UPDATE-RULE: invalid index")
             ~f:(fun idx ->
               Result.bind (parse_json_string json_str) ~f:(fun json ->
                   Result.bind (rule_of_yojson json) ~f:(fun r ->
                       Ok (Server_command { tenant; command = Update_rule (idx, r) }))))
         | _ -> Error "UPDATE-RULE: parse error")
     | "DELETE-RULE" ->
       (match words_n rest 2 with
        | Error e -> Error e
        | Ok [ tenant; idx_str ] ->
          (match Int.of_string_opt idx_str with
           | None -> Error "DELETE-RULE: invalid index"
           | Some idx ->
             Ok (Server_command { tenant; command = Delete_rule idx }))
        | Ok _ -> Error "DELETE-RULE: parse error")
     | other -> Error (Printf.sprintf "unknown command: %s" other))

(* ── Line protocol: responses ────────────────────────────────────── *)

let serialize_response : type a. a command -> a response -> string =
 fun cmd resp ->
  match resp with
  | Error msg -> Printf.sprintf "ERR %s" msg
  | Ok value ->
    (match cmd with
     | Register -> "OK"
     | Open _ ->
       (match value with
        | Local -> "LOCAL"
        | Remote tid -> Printf.sprintf "REMOTE %s" tid)
     | Open_on _ ->
       (match value with
        | Local -> "LOCAL"
        | Remote tid -> Printf.sprintf "REMOTE %s" tid)
     | Test _ ->
       (match value with
        | Match { tenant; rule_index } ->
          Printf.sprintf "MATCH %s %d" tenant rule_index
        | No_match { default_tenant } ->
          Printf.sprintf "NOMATCH %s" default_tenant)
     | Get_config ->
       Printf.sprintf "CONFIG %s"
         (config_to_yojson value |> Yojson.Safe.to_string)
     | Set_config _ -> "OK"
     | Add_rule _ -> "OK"
     | Update_rule _ -> "OK"
     | Delete_rule _ -> "OK"
     | Status ->
       Printf.sprintf "STATUS %s"
         (status_info_to_yojson value |> Yojson.Safe.to_string))

let deserialize_response :
    type a. a command -> string -> (a response, string) Result.t =
 fun cmd line ->
  match words_n line 2 with
  | Error _ ->
    (* single-word responses *)
    (match line with
     | "OK" ->
       (match cmd with
        | Register -> Ok (Ok ())
        | Set_config _ -> Ok (Ok ())
        | Add_rule _ -> Ok (Ok ())
        | Update_rule _ -> Ok (Ok ())
        | Delete_rule _ -> Ok (Ok ())
        | _ -> Error "unexpected OK for this command")
     | "LOCAL" ->
       (match cmd with
        | Open _ -> Ok (Ok Local)
        | Open_on _ -> Ok (Ok Local)
        | _ -> Error "unexpected LOCAL for this command")
     | other -> Error (Printf.sprintf "unrecognized response: %s" other))
  | Ok [ keyword; rest ] ->
    (match keyword with
     | "ERR" -> Ok (Error rest)
     | "REMOTE" ->
       (match cmd with
        | Open _ -> Ok (Ok (Remote rest))
        | Open_on _ -> Ok (Ok (Remote rest))
        | _ -> Error "unexpected REMOTE for this command")
     | "MATCH" ->
       (match cmd with
        | Test _ ->
          (match words_n rest 2 with
           | Ok [ tid; idx_str ] ->
             (match Int.of_string_opt idx_str with
              | Some idx ->
                Ok (Ok (Match { tenant = tid; rule_index = idx }))
              | None -> Error "MATCH: invalid index")
           | _ -> Error "MATCH: parse error")
        | _ -> Error "unexpected MATCH for this command")
     | "NOMATCH" ->
       (match cmd with
        | Test _ -> Ok (Ok (No_match { default_tenant = rest }))
        | _ -> Error "unexpected NOMATCH for this command")
     | "CONFIG" ->
       (match cmd with
        | Get_config ->
          Result.bind (parse_json_string rest) ~f:(fun json ->
              Result.bind (config_of_yojson json) ~f:(fun cfg ->
                  Ok (Ok cfg)))
        | _ -> Error "unexpected CONFIG for this command")
     | "STATUS" ->
       (match cmd with
        | Status ->
          Result.bind (parse_json_string rest) ~f:(fun json ->
              Result.bind (status_info_of_yojson json) ~f:(fun si ->
                  Ok (Ok si)))
        | _ -> Error "unexpected STATUS for this command")
     | other ->
       Error (Printf.sprintf "unrecognized response keyword: %s" other))
  | Ok _ -> Error "response parse error"

(* ── Line protocol: server push ──────────────────────────────────── *)

let serialize_push : type a. a server_push -> string =
 fun push ->
  match push with
  | Navigate url -> Printf.sprintf "NAVIGATE %s" url

let deserialize_push (line : string) : (packed_server_push, string) Result.t =
  match words_n line 2 with
  | Error e -> Error e
  | Ok [ keyword; rest ] ->
    (match keyword with
     | "NAVIGATE" -> Ok (Push (Navigate rest))
     | other -> Error (Printf.sprintf "unknown push: %s" other))
  | Ok _ -> Error "push parse error"

(* ── JSON serialization: commands ────────────────────────────────── *)

let serialize_command_json : type a. a command -> Yojson.Safe.t =
 fun cmd ->
  match cmd with
  | Register -> `Assoc [ ("command", `String "register") ]
  | Open url ->
    `Assoc [ ("command", `String "open"); ("url", `String url) ]
  | Open_on (target, url) ->
    `Assoc
      [
        ("command", `String "open_on");
        ("target", `String target);
        ("url", `String url);
      ]
  | Test url ->
    `Assoc [ ("command", `String "test"); ("url", `String url) ]
  | Get_config -> `Assoc [ ("command", `String "get_config") ]
  | Set_config cfg ->
    `Assoc
      [
        ("command", `String "set_config");
        ("config", config_to_yojson cfg);
      ]
  | Add_rule r ->
    `Assoc
      [ ("command", `String "add_rule"); ("rule", rule_to_yojson r) ]
  | Update_rule (idx, r) ->
    `Assoc
      [
        ("command", `String "update_rule");
        ("index", `Int idx);
        ("rule", rule_to_yojson r);
      ]
  | Delete_rule idx ->
    `Assoc
      [ ("command", `String "delete_rule"); ("index", `Int idx) ]
  | Status -> `Assoc [ ("command", `String "status") ]

let assoc_field (json : Yojson.Safe.t) (key : string) :
    (Yojson.Safe.t, string) Result.t =
  match json with
  | `Assoc pairs ->
    (match List.Assoc.find pairs ~equal:String.equal key with
     | Some v -> Ok v
     | None -> Error (Printf.sprintf "missing field: %s" key))
  | _ -> Error "expected JSON object"

let string_field (json : Yojson.Safe.t) (key : string) :
    (string, string) Result.t =
  match assoc_field json key with
  | Ok (`String s) -> Ok s
  | Ok _ -> Error (Printf.sprintf "field %s: expected string" key)
  | Error e -> Error e

let int_field (json : Yojson.Safe.t) (key : string) :
    (int, string) Result.t =
  match assoc_field json key with
  | Ok (`Int i) -> Ok i
  | Ok _ -> Error (Printf.sprintf "field %s: expected int" key)
  | Error e -> Error e

let deserialize_command_json (json : Yojson.Safe.t) :
    (packed_command, string) Result.t =
  match string_field json "command" with
  | Error e -> Error e
  | Ok cmd_name ->
    (match cmd_name with
     | "register" -> Ok (Command Register)
     | "open" ->
       Result.bind (string_field json "url") ~f:(fun url ->
           Ok (Command (Open url)))
     | "open_on" ->
       Result.bind (string_field json "target") ~f:(fun target ->
           Result.bind (string_field json "url") ~f:(fun url ->
               Ok (Command (Open_on (target, url)))))
     | "test" ->
       Result.bind (string_field json "url") ~f:(fun url ->
           Ok (Command (Test url)))
     | "get_config" -> Ok (Command Get_config)
     | "set_config" ->
       Result.bind (assoc_field json "config") ~f:(fun cfg_json ->
           Result.bind (config_of_yojson cfg_json) ~f:(fun cfg ->
               Ok (Command (Set_config cfg))))
     | "add_rule" ->
       Result.bind (assoc_field json "rule") ~f:(fun rule_json ->
           Result.bind (rule_of_yojson rule_json) ~f:(fun r ->
               Ok (Command (Add_rule r))))
     | "update_rule" ->
       Result.bind (int_field json "index") ~f:(fun idx ->
           Result.bind (assoc_field json "rule") ~f:(fun rule_json ->
               Result.bind (rule_of_yojson rule_json) ~f:(fun r ->
                   Ok (Command (Update_rule (idx, r))))))
     | "delete_rule" ->
       Result.bind (int_field json "index") ~f:(fun idx ->
           Ok (Command (Delete_rule idx)))
     | "status" -> Ok (Command Status)
     | other ->
       Error (Printf.sprintf "unknown command: %s" other))

(* ── JSON serialization: responses ───────────────────────────────── *)

let serialize_response_json :
    type a. a command -> a response -> Yojson.Safe.t =
 fun cmd resp ->
  match resp with
  | Error msg ->
    `Assoc [ ("status", `String "error"); ("message", `String msg) ]
  | Ok value ->
    (match cmd with
     | Register ->
       `Assoc [ ("status", `String "ok") ]
     | Open _ ->
       `Assoc
         [
           ("status", `String "ok");
           ("result", route_result_to_yojson value);
         ]
     | Open_on _ ->
       `Assoc
         [
           ("status", `String "ok");
           ("result", route_result_to_yojson value);
         ]
     | Test _ ->
       `Assoc
         [
           ("status", `String "ok");
           ("result", test_result_to_yojson value);
         ]
     | Get_config ->
       `Assoc
         [
           ("status", `String "ok");
           ("config", config_to_yojson value);
         ]
     | Set_config _ ->
       `Assoc [ ("status", `String "ok") ]
     | Add_rule _ ->
       `Assoc [ ("status", `String "ok") ]
     | Update_rule _ ->
       `Assoc [ ("status", `String "ok") ]
     | Delete_rule _ ->
       `Assoc [ ("status", `String "ok") ]
     | Status ->
       `Assoc
         [
           ("status", `String "ok");
           ("status_info", status_info_to_yojson value);
         ])

let deserialize_response_json :
    type a. a command -> Yojson.Safe.t -> (a response, string) Result.t =
 fun cmd json ->
  match string_field json "status" with
  | Error e -> Error e
  | Ok "error" ->
    (match string_field json "message" with
     | Ok msg -> Ok (Error msg)
     | Error e -> Error e)
  | Ok "ok" ->
    (match cmd with
     | Register -> Ok (Ok ())
     | Open _ ->
       (match assoc_field json "result" with
        | Error e -> Error e
        | Ok rj ->
          (match route_result_of_yojson rj with
           | Ok r -> Ok (Ok r)
           | Error e -> Error e))
     | Open_on _ ->
       (match assoc_field json "result" with
        | Error e -> Error e
        | Ok rj ->
          (match route_result_of_yojson rj with
           | Ok r -> Ok (Ok r)
           | Error e -> Error e))
     | Test _ ->
       (match assoc_field json "result" with
        | Error e -> Error e
        | Ok rj ->
          (match test_result_of_yojson rj with
           | Ok r -> Ok (Ok r)
           | Error e -> Error e))
     | Get_config ->
       (match assoc_field json "config" with
        | Error e -> Error e
        | Ok cj ->
          (match config_of_yojson cj with
           | Ok c -> Ok (Ok c)
           | Error e -> Error e))
     | Set_config _ -> Ok (Ok ())
     | Add_rule _ -> Ok (Ok ())
     | Update_rule _ -> Ok (Ok ())
     | Delete_rule _ -> Ok (Ok ())
     | Status ->
       (match assoc_field json "status_info" with
        | Error e -> Error e
        | Ok sj ->
          (match status_info_of_yojson sj with
           | Ok s -> Ok (Ok s)
           | Error e -> Error e)))
  | Ok other ->
    Error (Printf.sprintf "unknown status: %s" other)

(* ── Bridge message envelope ─────────────────────────────────────── *)

type bridge_message =
  | Response of Yojson.Safe.t
  | Push of packed_server_push

let bridge_message_to_yojson (msg : bridge_message) : Yojson.Safe.t =
  match msg with
  | Response json ->
    `Assoc [ ("type", `String "response"); ("data", json) ]
  | Push (Push (Navigate url)) ->
    `Assoc
      [
        ("type", `String "push");
        ("push_type", `String "navigate");
        ("url", `String url);
      ]

let bridge_message_of_yojson (json : Yojson.Safe.t) :
    (bridge_message, string) Result.t =
  match string_field json "type" with
  | Error e -> Error e
  | Ok "response" ->
    (match assoc_field json "data" with
     | Ok data -> Ok (Response data)
     | Error e -> Error e)
  | Ok "push" ->
    (match string_field json "push_type" with
     | Error e -> Error e
     | Ok "navigate" ->
       (match string_field json "url" with
        | Ok url -> Ok (Push (Push (Navigate url)))
        | Error e -> Error e)
     | Ok other ->
       Error (Printf.sprintf "unknown push_type: %s" other))
  | Ok other ->
    Error (Printf.sprintf "unknown bridge message type: %s" other)

(* Suppress unused open warnings — Stdio is used by convention *)
let () = ignore (print_endline : string -> unit)
