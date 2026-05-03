open !Base
open !Stdio

(* -- Constants *)

let default_port = 7120

(* -- Address parsing *)

type address = { host : string; port : int }

let parse_address (s : string) : address =
  let s = String.strip s in
  (* Handle IPv6 [host]:port *)
  match String.lsplit2 s ~on:']' with
  | Some (bracketed, after_bracket) ->
    let host = String.lstrip ~drop:(Char.equal '[') bracketed in
    let port =
      match String.lsplit2 after_bracket ~on:':' with
      | Some (_, p) -> Int.of_string_opt p |> Option.value ~default:default_port
      | None -> default_port
    in
    { host; port }
  | None ->
    begin match String.rsplit2 s ~on:':' with
    | Some (host, port_s) ->
      let port = Int.of_string_opt port_s |> Option.value ~default:default_port in
      { host; port }
    | None -> { host = s; port = default_port }
    end

(* -- CIDR parsing and matching *)

type cidr = { addr : bytes; prefix_len : int }

let parse_ipv4 s =
  let parts = String.split s ~on:'.' in
  match List.map parts ~f:Int.of_string_opt with
  | [ Some a; Some b; Some c; Some d ]
    when a >= 0 && a <= 255 && b >= 0 && b <= 255
         && c >= 0 && c <= 255 && d >= 0 && d <= 255 ->
    let buf = Bytes.create 4 in
    Bytes.set buf 0 (Char.of_int_exn a);
    Bytes.set buf 1 (Char.of_int_exn b);
    Bytes.set buf 2 (Char.of_int_exn c);
    Bytes.set buf 3 (Char.of_int_exn d);
    Some buf
  | _ -> None

let parse_hex_groups strs =
  let groups = List.map strs ~f:(fun p -> Int.of_string_opt ("0x" ^ p)) in
  match List.for_all groups ~f:Option.is_some with
  | true -> Some (List.filter_map groups ~f:Fn.id)
  | false -> None

let expand_ipv6_groups (s : string) : int list option =
  match String.substr_index s ~pattern:"::" with
  | Some idx ->
    let left_str = String.prefix s idx in
    let right_str = String.drop_prefix s (idx + 2) in
    let left_parts = match String.is_empty left_str with true -> [] | false -> String.split left_str ~on:':' in
    let right_parts = match String.is_empty right_str with true -> [] | false -> String.split right_str ~on:':' in
    begin match (parse_hex_groups left_parts, parse_hex_groups right_parts) with
    | (Some lv, Some rv) ->
      let pad_len = 8 - List.length lv - List.length rv in
      begin match pad_len >= 0 with
      | true -> Some (lv @ List.init pad_len ~f:(fun _ -> 0) @ rv)
      | false -> None
      end
    | _ -> None
    end
  | None ->
    let parts = String.split s ~on:':' in
    begin match List.length parts = 8 with
    | true -> parse_hex_groups parts
    | false -> None
    end

let groups_to_bytes vals =
  match List.length vals = 8
        && List.for_all vals ~f:(fun v -> v >= 0 && v <= 0xffff) with
  | false -> None
  | true ->
    let buf = Bytes.create 16 in
    List.iteri vals ~f:(fun i v ->
      Bytes.set buf (i * 2) (Char.of_int_exn ((v lsr 8) land 0xff));
      Bytes.set buf (i * 2 + 1) (Char.of_int_exn (v land 0xff)));
    Some buf

let parse_ipv6 s =
  Option.bind (expand_ipv6_groups s) ~f:groups_to_bytes

let ip_to_bytes (s : string) : bytes option =
  match parse_ipv4 s with
  | Some b -> Some b
  | None -> parse_ipv6 s

let parse_cidr (s : string) : cidr option =
  let make_cidr addr prefix_len =
    let max_bits = Bytes.length addr * 8 in
    match prefix_len >= 0 && prefix_len <= max_bits with
    | true -> Some { addr; prefix_len }
    | false -> None
  in
  match String.lsplit2 s ~on:'/' with
  | None ->
    Option.map (ip_to_bytes s) ~f:(fun addr ->
      { addr; prefix_len = Bytes.length addr * 8 })
  | Some (ip_str, prefix_str) ->
    begin match (ip_to_bytes ip_str, Int.of_string_opt prefix_str) with
    | (Some addr, Some prefix_len) -> make_cidr addr prefix_len
    | _ -> None
    end

let prefix_bytes_match ip_bytes cidr_bytes ~full_bytes =
  let rec check i =
    match i >= full_bytes with
    | true -> true
    | false ->
      match Char.equal (Bytes.get ip_bytes i) (Bytes.get cidr_bytes i) with
      | true -> check (i + 1)
      | false -> false
  in
  check 0

let partial_byte_matches ip_bytes cidr_bytes ~byte_idx ~remaining_bits =
  let mask = 0xff lsl (8 - remaining_bits) land 0xff in
  let ip_byte = Char.to_int (Bytes.get ip_bytes byte_idx) in
  let cidr_byte = Char.to_int (Bytes.get cidr_bytes byte_idx) in
  Int.equal (ip_byte land mask) (cidr_byte land mask)

let ip_in_cidr (ip : string) (cidr : cidr) : bool =
  match ip_to_bytes ip with
  | None -> false
  | Some ip_bytes ->
    match Bytes.length ip_bytes = Bytes.length cidr.addr with
    | false -> false
    | true ->
      let full_bytes = cidr.prefix_len / 8 in
      let remaining_bits = cidr.prefix_len % 8 in
      match prefix_bytes_match ip_bytes cidr.addr ~full_bytes with
      | false -> false
      | true ->
        match remaining_bits > 0 with
        | false -> true
        | true -> partial_byte_matches ip_bytes cidr.addr ~byte_idx:full_bytes ~remaining_bits

let ip_allowed ~allowed_networks ip =
  List.exists allowed_networks ~f:(fun cidr -> ip_in_cidr ip cidr)

let default_allowed_networks = [ "127.0.0.0/8"; "::1/128" ]

(* -- Core data types *)

type tenant_id = string [@@deriving yojson]
type url = string [@@deriving yojson]

type rule = {
  pattern : string;
  target : tenant_id;
  enabled : bool;
}
[@@deriving yojson]

type tenant_config = {
  browser_cmd : string option; [@default None]
  label : string;
  color : string;
  brand : string option; [@default None]
}
[@@deriving yojson]

type defaults = {
  unmatched : string;
  cooldown_seconds : int;
  browser_launch_timeout : int;
}
[@@deriving yojson]

(* Serialize tenant map as a JSON object keyed by tenant ID *)
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

let default_listen = [ "127.0.0.1:7120"; "[::1]:7120" ]

type config = {
  listen : string list; [@default default_listen]
  allowed_networks : string list; [@default default_allowed_networks]
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

(* -- Response payload types *)

type route_result =
  | Local
  | Remote of tenant_id
[@@deriving yojson]

type test_result =
  | Match of { tenant : tenant_id; rule_index : int }
  | No_match of { default_tenant : tenant_id }
[@@deriving yojson]

(* -- GADT command type *)

type _ command =
  | Register : string option -> string command
  | Open : url -> route_result command
  | Open_on : tenant_id * url -> route_result command
  | Test : url -> test_result command
  | Get_config : config command
  | Set_config : config -> unit command
  | Add_rule : rule -> unit command
  | Update_rule : int * rule -> unit command
  | Delete_rule : int -> unit command
  | Status : status_info command

(* -- Server push *)

type _ server_push =
  | Navigate : url -> url server_push
  | Config_updated : (config * string list) -> (config * string list) server_push

type packed_server_push = Push : 'a server_push -> packed_server_push

(* -- Existential wrappers *)

type packed_command = Command : 'a command -> packed_command

type 'a server_command = { tenant : tenant_id; command : 'a command }

type packed_server_command =
  | Server_command : 'a server_command -> packed_server_command

(* -- Helpers *)

let ( let* ) r f = Result.bind r ~f

let parse_json_string (s : string) : (Yojson.Safe.t, string) Result.t =
  match Yojson.Safe.from_string s with
  | json -> Ok json
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)

(* -- Line protocol: server commands *)

let serialize_server_command : type a. a server_command -> string =
 fun { tenant; command } ->
  match command with
  | Register brand ->
    (match brand with
     | Some b -> Printf.sprintf "REGISTER %s %s" tenant b
     | None -> Printf.sprintf "REGISTER %s" tenant)
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

let rejoin = String.concat ~sep:" "

let deserialize_server_command : string -> (packed_server_command, string) Result.t =
  fun line ->
  match String.split line ~on:' ' with
  | "REGISTER" :: tenant :: brand_parts ->
    let brand =
      match brand_parts with
      | [] -> None
      | _ -> Some (rejoin brand_parts)
    in
    Ok (Server_command { tenant; command = Register brand })
  | [ "STATUS"; tenant ] ->
    Ok (Server_command { tenant; command = Status })
  | [ "GET-CONFIG"; tenant ] ->
    Ok (Server_command { tenant; command = Get_config })
  | "OPEN" :: tenant :: (_ :: _ as url_parts) ->
    Ok (Server_command { tenant; command = Open (rejoin url_parts) })
  | "TEST" :: tenant :: (_ :: _ as url_parts) ->
    Ok (Server_command { tenant; command = Test (rejoin url_parts) })
  | "OPEN-ON" :: tenant :: target :: (_ :: _ as url_parts) ->
    Ok (Server_command { tenant; command = Open_on (target, rejoin url_parts) })
  | "SET-CONFIG" :: tenant :: (_ :: _ as json_parts) ->
    let* json = parse_json_string (rejoin json_parts) in
    let* cfg = config_of_yojson json in
    Ok (Server_command { tenant; command = Set_config cfg })
  | "ADD-RULE" :: tenant :: (_ :: _ as json_parts) ->
    let* json = parse_json_string (rejoin json_parts) in
    let* r = rule_of_yojson json in
    Ok (Server_command { tenant; command = Add_rule r })
  | "UPDATE-RULE" :: tenant :: idx_str :: (_ :: _ as json_parts) ->
    let* idx =
      Int.of_string_opt idx_str
      |> Result.of_option ~error:"UPDATE-RULE: invalid index"
    in
    let* json = parse_json_string (rejoin json_parts) in
    let* r = rule_of_yojson json in
    Ok (Server_command { tenant; command = Update_rule (idx, r) })
  | [ "DELETE-RULE"; tenant; idx_str ] ->
    let* idx =
      Int.of_string_opt idx_str
      |> Result.of_option ~error:"DELETE-RULE: invalid index"
    in
    Ok (Server_command { tenant; command = Delete_rule idx })
  | _ -> Error (Printf.sprintf "unknown command: %s" line)

(* -- Line protocol: responses *)

let serialize_response : type a. a command -> (a, string) Result.t -> string =
 fun cmd resp ->
  match resp with
  | Error msg -> Printf.sprintf "ERR %s" msg
  | Ok value ->
    (match cmd with
     | Register _ -> Printf.sprintf "OK %s" value
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
    type a. a command -> string -> (a, string) Result.t =
 fun cmd line ->
  match (cmd, String.split line ~on:' ') with
  | (_, "ERR" :: rest) -> Error (rejoin rest)
  | (Register _, [ "OK"; tid ]) -> Ok tid
  | (Set_config _, [ "OK" ]) -> Ok ()
  | (Add_rule _, [ "OK" ]) -> Ok ()
  | (Update_rule _, [ "OK" ]) -> Ok ()
  | (Delete_rule _, [ "OK" ]) -> Ok ()
  | (Open _, [ "LOCAL" ]) -> Ok Local
  | (Open_on _, [ "LOCAL" ]) -> Ok Local
  | (Open _, [ "REMOTE"; tid ]) -> Ok (Remote tid)
  | (Open_on _, [ "REMOTE"; tid ]) -> Ok (Remote tid)
  | (Test _, [ "MATCH"; tenant; idx_str ]) ->
    let* idx =
      Int.of_string_opt idx_str
      |> Result.of_option ~error:"MATCH: invalid index"
    in
    Ok (Match { tenant; rule_index = idx })
  | (Test _, [ "NOMATCH"; default_tenant ]) ->
    Ok (No_match { default_tenant })
  | (Get_config, "CONFIG" :: (_ :: _ as json_parts)) ->
    let* json = parse_json_string (rejoin json_parts) in
    let* cfg = config_of_yojson json in
    Ok cfg
  | (Status, "STATUS" :: (_ :: _ as json_parts)) ->
    let* json = parse_json_string (rejoin json_parts) in
    let* si = status_info_of_yojson json in
    Ok si
  | _ -> Error (Printf.sprintf "unrecognized response: %s" line)

(* -- Line protocol: server push *)

let serialize_push : type a. a server_push -> string =
 fun push ->
  match push with
  | Navigate url -> Printf.sprintf "NAVIGATE %s" url
  | Config_updated (cfg, registered) ->
    let json = `Assoc [
      ("config", config_to_yojson cfg);
      ("registered_tenants", `List (List.map registered ~f:(fun s -> `String s)));
    ] in
    Printf.sprintf "CONFIG_UPDATED %s" (Yojson.Safe.to_string json)

let deserialize_push (line : string) : (packed_server_push, string) Result.t =
  match String.split line ~on:' ' with
  | "NAVIGATE" :: (_ :: _ as url_parts) ->
    Ok (Push (Navigate (rejoin url_parts)))
  | "CONFIG_UPDATED" :: (_ :: _ as json_parts) ->
    let* json = parse_json_string (rejoin json_parts) in
    let* cfg = config_of_yojson (Yojson.Safe.Util.member "config" json) in
    let registered =
      match Yojson.Safe.Util.member "registered_tenants" json with
      | `List items ->
        List.filter_map items ~f:(function
          | `String s -> Some s
          | _ -> None)
      | _ -> []
    in
    Ok (Push (Config_updated (cfg, registered)))
  | _ -> Error (Printf.sprintf "unknown push: %s" line)

(* -- JSON wire types *)

module Wire = struct
  type command =
    | Register of { brand : string option [@default None]; address : string option [@default None]; name : string option [@default None] }
    | Open of { url : string }
    | Open_on of { target : string; url : string }
    | Test of { url : string }
    | Get_config
    | Set_config of { config : config }
    | Add_rule of { rule : rule }
    | Update_rule of { index : int; rule : rule }
    | Delete_rule of { index : int }
    | Status
  [@@deriving yojson]

  type response =
    | Ok_unit
    | Ok_registered of { tenant_id : string }
    | Ok_route of route_result
    | Ok_test of test_result
    | Ok_config of config
    | Ok_status of status_info
    | Err of { message : string }
  [@@deriving yojson]

  type push =
    | Navigate of { url : string }
    | Registered of { tenant_id : string }
    | Config_updated of { config : config; registered_tenants : string list }
  [@@deriving yojson]

  type bridge_message =
    | Response of response
    | Push of push
  [@@deriving yojson]
end

(* -- Wire type conversions *)

let command_to_wire : type a. a command -> Wire.command = function
  | Register brand -> Register { brand; address = None; name = None }
  | Open url -> Open { url }
  | Open_on (target, url) -> Open_on { target; url }
  | Test url -> Test { url }
  | Get_config -> Get_config
  | Set_config cfg -> Set_config { config = cfg }
  | Add_rule r -> Add_rule { rule = r }
  | Update_rule (idx, r) -> Update_rule { index = idx; rule = r }
  | Delete_rule idx -> Delete_rule { index = idx }
  | Status -> Status

let command_of_wire (w : Wire.command) : packed_command =
  match w with
  | Register { brand; _ } -> Command (Register brand)
  | Open { url } -> Command (Open url)
  | Open_on { target; url } -> Command (Open_on (target, url))
  | Test { url } -> Command (Test url)
  | Get_config -> Command Get_config
  | Set_config { config } -> Command (Set_config config)
  | Add_rule { rule } -> Command (Add_rule rule)
  | Update_rule { index; rule } -> Command (Update_rule (index, rule))
  | Delete_rule { index } -> Command (Delete_rule index)
  | Status -> Command Status

let response_to_wire : type a. a command -> (a, string) Result.t -> Wire.response =
 fun cmd resp ->
  match resp with
  | Error msg -> Err { message = msg }
  | Ok value ->
    (match cmd with
     | Register _ -> Ok_registered { tenant_id = value }
     | Open _ -> Ok_route value
     | Open_on _ -> Ok_route value
     | Test _ -> Ok_test value
     | Get_config -> Ok_config value
     | Set_config _ -> Ok_unit
     | Add_rule _ -> Ok_unit
     | Update_rule _ -> Ok_unit
     | Delete_rule _ -> Ok_unit
     | Status -> Ok_status value)

let response_of_wire : type a. a command -> Wire.response -> (a, string) Result.t =
 fun cmd wire ->
  match wire with
  | Err { message } -> Error message
  | Ok_unit ->
    (match cmd with
     | Set_config _ -> Ok ()
     | Add_rule _ -> Ok ()
     | Update_rule _ -> Ok ()
     | Delete_rule _ -> Ok ()
     | _ -> Error "unexpected Ok_unit for this command")
  | Ok_registered { tenant_id } ->
    (match cmd with
     | Register _ -> Ok tenant_id
     | _ -> Error "unexpected Ok_registered for this command")
  | Ok_route r ->
    (match cmd with
     | Open _ -> Ok r
     | Open_on _ -> Ok r
     | _ -> Error "unexpected Ok_route for this command")
  | Ok_test t ->
    (match cmd with
     | Test _ -> Ok t
     | _ -> Error "unexpected Ok_test for this command")
  | Ok_config c ->
    (match cmd with
     | Get_config -> Ok c
     | _ -> Error "unexpected Ok_config for this command")
  | Ok_status s ->
    (match cmd with
     | Status -> Ok s
     | _ -> Error "unexpected Ok_status for this command")

(* -- JSON serialization: commands *)

let serialize_command_json : type a. a command -> Yojson.Safe.t =
 fun cmd -> command_to_wire cmd |> Wire.command_to_yojson

let deserialize_command_json (json : Yojson.Safe.t) :
    (packed_command, string) Result.t =
  let* wire = Wire.command_of_yojson json in
  Ok (command_of_wire wire)

(* -- JSON serialization: responses *)

let serialize_response_json :
    type a. a command -> (a, string) Result.t -> Yojson.Safe.t =
 fun cmd resp -> response_to_wire cmd resp |> Wire.response_to_yojson

let deserialize_response_json :
    type a. a command -> Yojson.Safe.t -> (a, string) Result.t =
 fun cmd json ->
  match Wire.response_of_yojson json with
  | Error e -> Error e
  | Ok wire -> response_of_wire cmd wire

(* -- Bridge message envelope *)

let bridge_response_to_yojson :
    type a. a command -> (a, string) Result.t -> Yojson.Safe.t =
 fun cmd resp ->
  response_to_wire cmd resp
  |> fun w -> Wire.bridge_message_to_yojson (Response w)

let bridge_push_to_yojson (push : packed_server_push) : Yojson.Safe.t =
  match push with
  | Push (Navigate url) ->
    Wire.bridge_message_to_yojson (Push (Navigate { url }))
  | Push (Config_updated (cfg, registered)) ->
    Wire.bridge_message_to_yojson (Push (Config_updated { config = cfg; registered_tenants = registered }))

let bridge_message_of_yojson (json : Yojson.Safe.t) :
    (Wire.bridge_message, string) Result.t =
  Wire.bridge_message_of_yojson json

(* -- Inline expect tests *)

let%expect_test "sample data" =
  let _rule =
    { pattern = ".*[.]example[.]com"; target = "work"; enabled = true }
  in
  let _tenant_cfg =
    { browser_cmd = Some "chromium"; label = "Work"; color = "#0000ff"; brand = None }
  in
  let _defaults =
    { unmatched = "personal"; cooldown_seconds = 5; browser_launch_timeout = 10 }
  in
  [%expect {||}]

(* -- Line protocol: server commands *)

let%expect_test "line: serialize register" =
  print_endline (serialize_server_command { tenant = "host"; command = Register (Some "Google Chrome") });
  [%expect {| REGISTER host Google Chrome |}]

let%expect_test "line: serialize open" =
  print_endline
    (serialize_server_command
       { tenant = "work"; command = Open "https://example.com" });
  [%expect {| OPEN work https://example.com |}]

let%expect_test "line: serialize open-on" =
  print_endline
    (serialize_server_command
       { tenant = "host"; command = Open_on ("work", "https://example.com/page") });
  [%expect {| OPEN-ON host work https://example.com/page |}]

let%expect_test "line: serialize test" =
  print_endline
    (serialize_server_command { tenant = "work"; command = Test "https://test.com" });
  [%expect {| TEST work https://test.com |}]

let%expect_test "line: serialize get-config" =
  print_endline (serialize_server_command { tenant = "host"; command = Get_config });
  [%expect {| GET-CONFIG host |}]

let%expect_test "line: serialize delete-rule" =
  print_endline
    (serialize_server_command { tenant = "host"; command = Delete_rule 3 });
  [%expect {| DELETE-RULE host 3 |}]

let%expect_test "line: serialize status" =
  print_endline (serialize_server_command { tenant = "host"; command = Status });
  [%expect {| STATUS host |}]

let%expect_test "line: round-trip register" =
  let line = serialize_server_command { tenant = "host"; command = Register (Some "Microsoft Edge") } in
  (match deserialize_server_command line with
   | Ok (Server_command { tenant; command = Register (Some brand) }) ->
     printf "tenant=%s brand=%s\n" tenant brand
   | _ -> print_endline "FAIL");
  [%expect {| tenant=host brand=Microsoft Edge |}]

let%expect_test "line: round-trip open with spaces in url" =
  let sc =
    { tenant = "work"; command = Open "https://example.com/search?q=hello world" }
  in
  let line = serialize_server_command sc in
  (match deserialize_server_command line with
   | Ok (Server_command { tenant; command = Open url }) ->
     printf "tenant=%s url=%s\n" tenant url
   | _ -> print_endline "FAIL");
  [%expect {| tenant=work url=https://example.com/search?q=hello world |}]

let%expect_test "line: round-trip open_on" =
  let sc =
    { tenant = "host"; command = Open_on ("work", "https://example.com/page") }
  in
  let line = serialize_server_command sc in
  (match deserialize_server_command line with
   | Ok (Server_command { tenant; command = Open_on (target, url) }) ->
     printf "tenant=%s target=%s url=%s\n" tenant target url
   | _ -> print_endline "FAIL");
  [%expect {| tenant=host target=work url=https://example.com/page |}]

let sample_config =
  {
    listen = [ "127.0.0.1:7120"; "[::1]:7120" ];
    allowed_networks = default_allowed_networks;
    tenants =
      [
        ( "work",
          { browser_cmd = Some "chromium --profile-directory=Work";
            label = "Work";
            color = "#0000ff";
            brand = Some "Google Chrome" } );
      ];
    rules =
      [ { pattern = ".*[.]example[.]com"; target = "work"; enabled = true } ];
    defaults =
      { unmatched = "personal"; cooldown_seconds = 5; browser_launch_timeout = 10 };
  }

let%expect_test "line: round-trip set_config" =
  let line =
    serialize_server_command { tenant = "host"; command = Set_config sample_config }
  in
  (match deserialize_server_command line with
   | Ok (Server_command { tenant; command = Set_config cfg }) ->
     printf "tenant=%s listen=%s rules=%d\n" tenant
       (String.concat ~sep:"," cfg.listen)
       (List.length cfg.rules)
   | _ -> print_endline "FAIL");
  [%expect {| tenant=host listen=127.0.0.1:7120,[::1]:7120 rules=1 |}]

let sample_rule =
  { pattern = ".*[.]example[.]com"; target = "work"; enabled = true }

let%expect_test "line: round-trip add_rule" =
  let line =
    serialize_server_command { tenant = "host"; command = Add_rule sample_rule }
  in
  (match deserialize_server_command line with
   | Ok (Server_command { tenant; command = Add_rule r }) ->
     printf "tenant=%s pattern=%s target=%s enabled=%b\n" tenant r.pattern
       r.target r.enabled
   | _ -> print_endline "FAIL");
  [%expect {| tenant=host pattern=.*[.]example[.]com target=work enabled=true |}]

let%expect_test "line: round-trip update_rule" =
  let line =
    serialize_server_command
      { tenant = "host"; command = Update_rule (2, sample_rule) }
  in
  (match deserialize_server_command line with
   | Ok (Server_command { tenant; command = Update_rule (idx, r) }) ->
     printf "tenant=%s idx=%d pattern=%s\n" tenant idx r.pattern
   | _ -> print_endline "FAIL");
  [%expect {| tenant=host idx=2 pattern=.*[.]example[.]com |}]

let%expect_test "line: round-trip delete_rule" =
  let line =
    serialize_server_command { tenant = "host"; command = Delete_rule 3 }
  in
  (match deserialize_server_command line with
   | Ok (Server_command { tenant; command = Delete_rule idx }) ->
     printf "tenant=%s idx=%d\n" tenant idx
   | _ -> print_endline "FAIL");
  [%expect {| tenant=host idx=3 |}]

(* -- Line protocol: responses *)

let%expect_test "line: response OK" =
  print_endline (serialize_response (Register None) (Ok "myhost"));
  [%expect {| OK myhost |}]

let%expect_test "line: response LOCAL" =
  print_endline (serialize_response (Open "https://x.com") (Ok Local));
  [%expect {| LOCAL |}]

let%expect_test "line: response REMOTE" =
  print_endline (serialize_response (Open "https://x.com") (Ok (Remote "work")));
  [%expect {| REMOTE work |}]

let%expect_test "line: response MATCH" =
  print_endline
    (serialize_response (Test "https://x.com")
       (Ok (Match { tenant = "work"; rule_index = 1 })));
  [%expect {| MATCH work 1 |}]

let%expect_test "line: response NOMATCH" =
  print_endline
    (serialize_response (Test "https://x.com")
       (Ok (No_match { default_tenant = "personal" })));
  [%expect {| NOMATCH personal |}]

let%expect_test "line: response ERR" =
  print_endline (serialize_response (Register None) (Error "something went wrong"));
  [%expect {| ERR something went wrong |}]

let%expect_test "line: round-trip response config" =
  let cmd = Get_config in
  let line = serialize_response cmd (Ok sample_config) in
  (match deserialize_response cmd line with
   | Ok cfg ->
     printf "listen=%s rules=%d\n" (String.concat ~sep:"," cfg.listen) (List.length cfg.rules)
   | _ -> print_endline "FAIL");
  [%expect {| listen=127.0.0.1:7120,[::1]:7120 rules=1 |}]

let sample_status =
  { registered_tenants = [ "work"; "personal" ]; uptime_seconds = 3600 }

let%expect_test "line: round-trip response status" =
  let cmd = Status in
  let line = serialize_response cmd (Ok sample_status) in
  (match deserialize_response cmd line with
   | Ok si ->
     printf "uptime=%d tenants=%d\n" si.uptime_seconds
       (List.length si.registered_tenants)
   | _ -> print_endline "FAIL");
  [%expect {| uptime=3600 tenants=2 |}]

let%expect_test "line: round-trip response err with special chars" =
  let cmd = Register None in
  let line = serialize_response cmd (Error "fail: \"bad\" & <oops>") in
  (match deserialize_response cmd line with
   | Error msg -> printf "err=%s\n" msg
   | _ -> print_endline "FAIL");
  [%expect {| err=fail: "bad" & <oops> |}]

(* -- Line protocol: server push *)

let%expect_test "line: push navigate" =
  print_endline (serialize_push (Navigate "https://example.com/path"));
  [%expect {| NAVIGATE https://example.com/path |}]

let%expect_test "line: round-trip push navigate with spaces" =
  let line = serialize_push (Navigate "https://example.com/q=hello world") in
  (match deserialize_push line with
   | Ok (Push (Navigate url)) -> printf "url=%s\n" url
   | _ -> print_endline "FAIL");
  [%expect {| url=https://example.com/q=hello world |}]

let%expect_test "line: round-trip push config_updated" =
  let cfg : config = {
    listen = ["127.0.0.1:7120"];
    allowed_networks = ["127.0.0.0/8"];
    tenants = [("work", { browser_cmd = None; label = "Work"; color = "#ff0000"; brand = None })];
    rules = [];
    defaults = { unmatched = "local"; cooldown_seconds = 5; browser_launch_timeout = 10 };
  } in
  let registered = ["work"; "personal"] in
  let line = serialize_push (Config_updated (cfg, registered)) in
  (match deserialize_push line with
   | Ok (Push (Config_updated (c, r))) ->
     printf "tenants=%d registered=%d\n" (List.length c.tenants) (List.length r)
   | _ -> print_endline "FAIL");
  [%expect {| tenants=1 registered=2 |}]

(* -- JSON: commands *)

let%expect_test "json: round-trip register" =
  let json = serialize_command_json (Register (Some "Google Chrome")) in
  print_endline (Yojson.Safe.to_string json);
  (match deserialize_command_json json with
   | Ok (Command (Register (Some brand))) -> printf "brand=%s\n" brand
   | _ -> print_endline "FAIL");
  [%expect {|
    ["Register",{"brand":"Google Chrome"}]
    brand=Google Chrome
    |}]

let%expect_test "json: round-trip open" =
  let json = serialize_command_json (Open "https://example.com") in
  print_endline (Yojson.Safe.to_string json);
  (match deserialize_command_json json with
   | Ok (Command (Open url)) -> printf "url=%s\n" url
   | _ -> print_endline "FAIL");
  [%expect {|
    ["Open",{"url":"https://example.com"}]
    url=https://example.com
    |}]

let%expect_test "json: round-trip open_on" =
  let json = serialize_command_json (Open_on ("work", "https://example.com")) in
  (match deserialize_command_json json with
   | Ok (Command (Open_on (target, url))) ->
     printf "target=%s url=%s\n" target url
   | _ -> print_endline "FAIL");
  [%expect {| target=work url=https://example.com |}]

let%expect_test "json: round-trip test" =
  let json = serialize_command_json (Test "https://example.com") in
  (match deserialize_command_json json with
   | Ok (Command (Test url)) -> printf "url=%s\n" url
   | _ -> print_endline "FAIL");
  [%expect {| url=https://example.com |}]

let%expect_test "json: round-trip set_config" =
  let json = serialize_command_json (Set_config sample_config) in
  (match deserialize_command_json json with
   | Ok (Command (Set_config cfg)) ->
     printf "listen=%s\n" (String.concat ~sep:"," cfg.listen)
   | _ -> print_endline "FAIL");
  [%expect {| listen=127.0.0.1:7120,[::1]:7120 |}]

let%expect_test "json: round-trip add_rule" =
  let json = serialize_command_json (Add_rule sample_rule) in
  (match deserialize_command_json json with
   | Ok (Command (Add_rule r)) -> printf "pattern=%s\n" r.pattern
   | _ -> print_endline "FAIL");
  [%expect {| pattern=.*[.]example[.]com |}]

let%expect_test "json: round-trip update_rule" =
  let json = serialize_command_json (Update_rule (5, sample_rule)) in
  (match deserialize_command_json json with
   | Ok (Command (Update_rule (idx, r))) ->
     printf "idx=%d pattern=%s\n" idx r.pattern
   | _ -> print_endline "FAIL");
  [%expect {| idx=5 pattern=.*[.]example[.]com |}]

let%expect_test "json: round-trip delete_rule" =
  let json = serialize_command_json (Delete_rule 7) in
  (match deserialize_command_json json with
   | Ok (Command (Delete_rule idx)) -> printf "idx=%d\n" idx
   | _ -> print_endline "FAIL");
  [%expect {| idx=7 |}]

(* -- JSON: responses *)

let%expect_test "json: response ok" =
  let json = serialize_response_json (Register None) (Ok "myhost") in
  print_endline (Yojson.Safe.to_string json);
  [%expect {| ["Ok_registered",{"tenant_id":"myhost"}] |}]

let%expect_test "json: response local" =
  let json = serialize_response_json (Open "https://x.com") (Ok Local) in
  print_endline (Yojson.Safe.to_string json);
  [%expect {| ["Ok_route",["Local"]] |}]

let%expect_test "json: response remote" =
  let json =
    serialize_response_json (Open "https://x.com") (Ok (Remote "work"))
  in
  print_endline (Yojson.Safe.to_string json);
  [%expect {| ["Ok_route",["Remote","work"]] |}]

let%expect_test "json: response match" =
  let json =
    serialize_response_json (Test "https://x.com")
      (Ok (Match { tenant = "work"; rule_index = 2 }))
  in
  print_endline (Yojson.Safe.to_string json);
  [%expect {| ["Ok_test",["Match",{"tenant":"work","rule_index":2}]] |}]

let%expect_test "json: response nomatch" =
  let json =
    serialize_response_json (Test "https://x.com")
      (Ok (No_match { default_tenant = "personal" }))
  in
  print_endline (Yojson.Safe.to_string json);
  [%expect {| ["Ok_test",["No_match",{"default_tenant":"personal"}]] |}]

let%expect_test "json: response error" =
  let json = serialize_response_json (Register None) (Error "bad request") in
  print_endline (Yojson.Safe.to_string json);
  [%expect {| ["Err",{"message":"bad request"}] |}]

let%expect_test "json: round-trip response config" =
  let cmd = Get_config in
  let json = serialize_response_json cmd (Ok sample_config) in
  (match deserialize_response_json cmd json with
   | Ok cfg -> printf "listen=%s\n" (String.concat ~sep:"," cfg.listen)
   | _ -> print_endline "FAIL");
  [%expect {| listen=127.0.0.1:7120,[::1]:7120 |}]

let%expect_test "json: round-trip response status" =
  let cmd = Status in
  let json = serialize_response_json cmd (Ok sample_status) in
  (match deserialize_response_json cmd json with
   | Ok si -> printf "uptime=%d\n" si.uptime_seconds
   | _ -> print_endline "FAIL");
  [%expect {| uptime=3600 |}]

(* -- JSON: bridge messages *)

let%expect_test "json: bridge push round-trip" =
  let json = bridge_push_to_yojson (Push (Navigate "https://example.com")) in
  print_endline (Yojson.Safe.to_string json);
  (match bridge_message_of_yojson json with
   | Ok (Wire.Push (Wire.Navigate { url })) -> printf "url=%s\n" url
   | _ -> print_endline "FAIL");
  [%expect {|
    ["Push",["Navigate",{"url":"https://example.com"}]]
    url=https://example.com |}]

let%expect_test "json: bridge push config_updated round-trip" =
  let cfg : config = {
    listen = ["127.0.0.1:7120"];
    allowed_networks = ["127.0.0.0/8"];
    tenants = [("work", { browser_cmd = None; label = "Work"; color = "#ff0000"; brand = None })];
    rules = [];
    defaults = { unmatched = "local"; cooldown_seconds = 5; browser_launch_timeout = 10 };
  } in
  let json = bridge_push_to_yojson (Push (Config_updated (cfg, ["work"]))) in
  (match bridge_message_of_yojson json with
   | Ok (Wire.Push (Wire.Config_updated { config = c; registered_tenants = r })) ->
     printf "tenants=%d registered=%d\n" (List.length c.tenants) (List.length r)
   | _ -> print_endline "FAIL");
  [%expect {| tenants=1 registered=1 |}]

let%expect_test "json: bridge response round-trip" =
  let json = bridge_response_to_yojson (Register None) (Ok "myhost") in
  (match bridge_message_of_yojson json with
   | Ok (Wire.Response (Wire.Ok_registered { tenant_id })) -> printf "registered=%s\n" tenant_id
   | _ -> print_endline "FAIL");
  [%expect {| registered=myhost |}]

(* -- Error handling *)

let%expect_test "deserialize: invalid json string" =
  (match parse_json_string "not valid json{" with
   | Error msg -> printf "error=%s\n" msg
   | Ok _ -> print_endline "UNEXPECTED OK");
  [%expect {|
    error=invalid JSON: Line 1, bytes 0-15:
    Invalid token 'not valid json{'
    |}]

let%expect_test "deserialize: unknown command" =
  (match deserialize_server_command "BOGUS host" with
   | Error msg -> printf "error=%s\n" msg
   | Ok _ -> print_endline "UNEXPECTED OK");
  [%expect {| error=unknown command: BOGUS host |}]

let%expect_test "deserialize: empty line" =
  (match deserialize_server_command "" with
   | Error msg -> printf "error=%s\n" msg
   | Ok _ -> print_endline "UNEXPECTED OK");
  [%expect {| error=unknown command: |}]
