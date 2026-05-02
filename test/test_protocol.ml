open Base
open Stdio

let () = ignore (print_endline : string -> unit)

open Protocol

(* ── Test helpers ────────────────────────────────────────────────── *)

let sample_rule =
  { pattern = ".*\\.example\\.com"; target = "work"; enabled = true }

let sample_tenant_config =
  {
    browser_cmd = "chromium --profile-directory=Work";
    label = "Work";
    color = "#0000ff";
  }

let sample_defaults =
  {
    unmatched = "personal";
    cooldown_seconds = 5;
    browser_launch_timeout = 10;
  }

let sample_config =
  {
    socket = "/run/url-router.sock";
    tenants = [ ("work", sample_tenant_config) ];
    rules = [ sample_rule ];
    defaults = sample_defaults;
  }

let sample_status =
  { registered_tenants = [ "work"; "personal" ]; uptime_seconds = 3600 }

(* ── Line protocol round-trip: server commands ───────────────────── *)

let test_line_rt_register () =
  let sc = { tenant = "host"; command = Register } in
  let line = serialize_server_command sc in
  Alcotest.(check string) "serialize" "REGISTER host" line;
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Register }) ->
    Alcotest.(check string) "tenant" "host" tenant
  | _ -> Alcotest.fail "deserialize register"

let test_line_rt_open () =
  let sc = { tenant = "work"; command = Open "https://example.com" } in
  let line = serialize_server_command sc in
  Alcotest.(check string) "serialize" "OPEN work https://example.com" line;
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Open url }) ->
    Alcotest.(check string) "tenant" "work" tenant;
    Alcotest.(check string) "url" "https://example.com" url
  | _ -> Alcotest.fail "deserialize open"

let test_line_rt_open_url_with_spaces () =
  let sc =
    { tenant = "work"; command = Open "https://example.com/search?q=hello world" }
  in
  let line = serialize_server_command sc in
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Open url }) ->
    Alcotest.(check string) "tenant" "work" tenant;
    Alcotest.(check string) "url" "https://example.com/search?q=hello world" url
  | _ -> Alcotest.fail "deserialize open with spaces"

let test_line_rt_open_on () =
  let sc =
    {
      tenant = "host";
      command = Open_on ("work", "https://example.com/page");
    }
  in
  let line = serialize_server_command sc in
  Alcotest.(check string) "serialize"
    "OPEN-ON host work https://example.com/page" line;
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Open_on (target, url) }) ->
    Alcotest.(check string) "tenant" "host" tenant;
    Alcotest.(check string) "target" "work" target;
    Alcotest.(check string) "url" "https://example.com/page" url
  | _ -> Alcotest.fail "deserialize open_on"

let test_line_rt_test () =
  let sc = { tenant = "work"; command = Test "https://test.com" } in
  let line = serialize_server_command sc in
  Alcotest.(check string) "serialize" "TEST work https://test.com" line;
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Test url }) ->
    Alcotest.(check string) "tenant" "work" tenant;
    Alcotest.(check string) "url" "https://test.com" url
  | _ -> Alcotest.fail "deserialize test"

let test_line_rt_get_config () =
  let sc = { tenant = "host"; command = Get_config } in
  let line = serialize_server_command sc in
  Alcotest.(check string) "serialize" "GET-CONFIG host" line;
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Get_config }) ->
    Alcotest.(check string) "tenant" "host" tenant
  | _ -> Alcotest.fail "deserialize get_config"

let test_line_rt_set_config () =
  let sc = { tenant = "host"; command = Set_config sample_config } in
  let line = serialize_server_command sc in
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Set_config cfg }) ->
    Alcotest.(check string) "tenant" "host" tenant;
    Alcotest.(check string) "socket" sample_config.socket cfg.socket
  | _ -> Alcotest.fail "deserialize set_config"

let test_line_rt_add_rule () =
  let sc = { tenant = "host"; command = Add_rule sample_rule } in
  let line = serialize_server_command sc in
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Add_rule r }) ->
    Alcotest.(check string) "tenant" "host" tenant;
    Alcotest.(check string) "pattern" sample_rule.pattern r.pattern;
    Alcotest.(check string) "target" sample_rule.target r.target;
    Alcotest.(check bool) "enabled" sample_rule.enabled r.enabled
  | _ -> Alcotest.fail "deserialize add_rule"

let test_line_rt_update_rule () =
  let sc =
    { tenant = "host"; command = Update_rule (2, sample_rule) }
  in
  let line = serialize_server_command sc in
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Update_rule (idx, r) }) ->
    Alcotest.(check string) "tenant" "host" tenant;
    Alcotest.(check int) "index" 2 idx;
    Alcotest.(check string) "pattern" sample_rule.pattern r.pattern
  | _ -> Alcotest.fail "deserialize update_rule"

let test_line_rt_delete_rule () =
  let sc = { tenant = "host"; command = Delete_rule 3 } in
  let line = serialize_server_command sc in
  Alcotest.(check string) "serialize" "DELETE-RULE host 3" line;
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Delete_rule idx }) ->
    Alcotest.(check string) "tenant" "host" tenant;
    Alcotest.(check int) "index" 3 idx
  | _ -> Alcotest.fail "deserialize delete_rule"

let test_line_rt_status () =
  let sc = { tenant = "host"; command = Status } in
  let line = serialize_server_command sc in
  Alcotest.(check string) "serialize" "STATUS host" line;
  match deserialize_server_command line with
  | Ok (Server_command { tenant; command = Status }) ->
    Alcotest.(check string) "tenant" "host" tenant
  | _ -> Alcotest.fail "deserialize status"

(* ── Line protocol round-trip: responses ─────────────────────────── *)

let test_line_resp_ok () =
  let cmd = Register in
  let resp : unit response = Ok () in
  let line = serialize_response cmd resp in
  Alcotest.(check string) "serialize" "OK" line;
  match deserialize_response cmd line with
  | Ok (Ok ()) -> ()
  | _ -> Alcotest.fail "deserialize ok"

let test_line_resp_local () =
  let cmd = Open "https://x.com" in
  let resp : route_result response = Ok Local in
  let line = serialize_response cmd resp in
  Alcotest.(check string) "serialize" "LOCAL" line;
  match deserialize_response cmd line with
  | Ok (Ok Local) -> ()
  | _ -> Alcotest.fail "deserialize local"

let test_line_resp_remote () =
  let cmd = Open "https://x.com" in
  let resp : route_result response = Ok (Remote "work") in
  let line = serialize_response cmd resp in
  Alcotest.(check string) "serialize" "REMOTE work" line;
  match deserialize_response cmd line with
  | Ok (Ok (Remote tid)) ->
    Alcotest.(check string) "tenant" "work" tid
  | _ -> Alcotest.fail "deserialize remote"

let test_line_resp_remote_open_on () =
  let cmd = Open_on ("work", "https://x.com") in
  let resp : route_result response = Ok (Remote "work") in
  let line = serialize_response cmd resp in
  Alcotest.(check string) "serialize" "REMOTE work" line;
  match deserialize_response cmd line with
  | Ok (Ok (Remote tid)) ->
    Alcotest.(check string) "tenant" "work" tid
  | _ -> Alcotest.fail "deserialize remote open_on"

let test_line_resp_match () =
  let cmd = Test "https://x.com" in
  let resp : test_result response =
    Ok (Match { tenant = "work"; rule_index = 1 })
  in
  let line = serialize_response cmd resp in
  Alcotest.(check string) "serialize" "MATCH work 1" line;
  match deserialize_response cmd line with
  | Ok (Ok (Match { tenant; rule_index })) ->
    Alcotest.(check string) "tenant" "work" tenant;
    Alcotest.(check int) "rule_index" 1 rule_index
  | _ -> Alcotest.fail "deserialize match"

let test_line_resp_nomatch () =
  let cmd = Test "https://x.com" in
  let resp : test_result response =
    Ok (No_match { default_tenant = "personal" })
  in
  let line = serialize_response cmd resp in
  Alcotest.(check string) "serialize" "NOMATCH personal" line;
  match deserialize_response cmd line with
  | Ok (Ok (No_match { default_tenant })) ->
    Alcotest.(check string) "default" "personal" default_tenant
  | _ -> Alcotest.fail "deserialize nomatch"

let test_line_resp_config () =
  let cmd = Get_config in
  let resp : config response = Ok sample_config in
  let line = serialize_response cmd resp in
  match deserialize_response cmd line with
  | Ok (Ok cfg) ->
    Alcotest.(check string) "socket" sample_config.socket cfg.socket;
    Alcotest.(check int) "rules_len"
      (List.length sample_config.rules)
      (List.length cfg.rules)
  | _ -> Alcotest.fail "deserialize config response"

let test_line_resp_status () =
  let cmd = Status in
  let resp : status_info response = Ok sample_status in
  let line = serialize_response cmd resp in
  match deserialize_response cmd line with
  | Ok (Ok si) ->
    Alcotest.(check int) "uptime" 3600 si.uptime_seconds;
    Alcotest.(check int) "tenants"
      (List.length sample_status.registered_tenants)
      (List.length si.registered_tenants)
  | _ -> Alcotest.fail "deserialize status response"

let test_line_resp_err () =
  let cmd = Register in
  let resp : unit response = Error "something went wrong" in
  let line = serialize_response cmd resp in
  Alcotest.(check string) "serialize" "ERR something went wrong" line;
  match deserialize_response cmd line with
  | Ok (Error msg) ->
    Alcotest.(check string) "msg" "something went wrong" msg
  | _ -> Alcotest.fail "deserialize err"

let test_line_resp_err_special_chars () =
  let cmd = Register in
  let resp : unit response = Error "fail: \"bad\" & <oops>" in
  let line = serialize_response cmd resp in
  match deserialize_response cmd line with
  | Ok (Error msg) ->
    Alcotest.(check string) "msg" "fail: \"bad\" & <oops>" msg
  | _ -> Alcotest.fail "deserialize err special"

(* ── Line protocol round-trip: server push ───────────────────────── *)

let test_line_push_navigate () =
  let push = Navigate "https://example.com/path" in
  let line = serialize_push push in
  Alcotest.(check string) "serialize" "NAVIGATE https://example.com/path" line;
  match deserialize_push line with
  | Ok (Push (Navigate url)) ->
    Alcotest.(check string) "url" "https://example.com/path" url
  | Error e -> Alcotest.fail e

let test_line_push_navigate_spaces () =
  let push = Navigate "https://example.com/search?q=hello world" in
  let line = serialize_push push in
  match deserialize_push line with
  | Ok (Push (Navigate url)) ->
    Alcotest.(check string) "url" "https://example.com/search?q=hello world" url
  | Error e -> Alcotest.fail e

(* ── JSON round-trip: commands ───────────────────────────────────── *)

let test_json_cmd_register () =
  let json = serialize_command_json Register in
  match deserialize_command_json json with
  | Ok (Command Register) -> ()
  | _ -> Alcotest.fail "json register"

let test_json_cmd_open () =
  let json = serialize_command_json (Open "https://example.com") in
  match deserialize_command_json json with
  | Ok (Command (Open url)) ->
    Alcotest.(check string) "url" "https://example.com" url
  | _ -> Alcotest.fail "json open"

let test_json_cmd_open_on () =
  let json =
    serialize_command_json (Open_on ("work", "https://example.com"))
  in
  match deserialize_command_json json with
  | Ok (Command (Open_on (target, url))) ->
    Alcotest.(check string) "target" "work" target;
    Alcotest.(check string) "url" "https://example.com" url
  | _ -> Alcotest.fail "json open_on"

let test_json_cmd_test () =
  let json = serialize_command_json (Test "https://example.com") in
  match deserialize_command_json json with
  | Ok (Command (Test url)) ->
    Alcotest.(check string) "url" "https://example.com" url
  | _ -> Alcotest.fail "json test"

let test_json_cmd_get_config () =
  let json = serialize_command_json Get_config in
  match deserialize_command_json json with
  | Ok (Command Get_config) -> ()
  | _ -> Alcotest.fail "json get_config"

let test_json_cmd_set_config () =
  let json = serialize_command_json (Set_config sample_config) in
  match deserialize_command_json json with
  | Ok (Command (Set_config cfg)) ->
    Alcotest.(check string) "socket" sample_config.socket cfg.socket
  | _ -> Alcotest.fail "json set_config"

let test_json_cmd_add_rule () =
  let json = serialize_command_json (Add_rule sample_rule) in
  match deserialize_command_json json with
  | Ok (Command (Add_rule r)) ->
    Alcotest.(check string) "pattern" sample_rule.pattern r.pattern
  | _ -> Alcotest.fail "json add_rule"

let test_json_cmd_update_rule () =
  let json =
    serialize_command_json (Update_rule (5, sample_rule))
  in
  match deserialize_command_json json with
  | Ok (Command (Update_rule (idx, r))) ->
    Alcotest.(check int) "index" 5 idx;
    Alcotest.(check string) "pattern" sample_rule.pattern r.pattern
  | _ -> Alcotest.fail "json update_rule"

let test_json_cmd_delete_rule () =
  let json = serialize_command_json (Delete_rule 7) in
  match deserialize_command_json json with
  | Ok (Command (Delete_rule idx)) ->
    Alcotest.(check int) "index" 7 idx
  | _ -> Alcotest.fail "json delete_rule"

let test_json_cmd_status () =
  let json = serialize_command_json Status in
  match deserialize_command_json json with
  | Ok (Command Status) -> ()
  | _ -> Alcotest.fail "json status"

(* ── JSON round-trip: responses ──────────────────────────────────── *)

let test_json_resp_ok () =
  let cmd = Register in
  let resp : unit response = Ok () in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok ()) -> ()
  | _ -> Alcotest.fail "json resp ok"

let test_json_resp_local () =
  let cmd = Open "https://x.com" in
  let resp : route_result response = Ok Local in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok Local) -> ()
  | _ -> Alcotest.fail "json resp local"

let test_json_resp_remote () =
  let cmd = Open "https://x.com" in
  let resp : route_result response = Ok (Remote "work") in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok (Remote tid)) ->
    Alcotest.(check string) "tenant" "work" tid
  | _ -> Alcotest.fail "json resp remote"

let test_json_resp_match () =
  let cmd = Test "https://x.com" in
  let resp : test_result response =
    Ok (Match { tenant = "work"; rule_index = 2 })
  in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok (Match { tenant; rule_index })) ->
    Alcotest.(check string) "tenant" "work" tenant;
    Alcotest.(check int) "rule_index" 2 rule_index
  | _ -> Alcotest.fail "json resp match"

let test_json_resp_nomatch () =
  let cmd = Test "https://x.com" in
  let resp : test_result response =
    Ok (No_match { default_tenant = "personal" })
  in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok (No_match { default_tenant })) ->
    Alcotest.(check string) "default" "personal" default_tenant
  | _ -> Alcotest.fail "json resp nomatch"

let test_json_resp_config () =
  let cmd = Get_config in
  let resp : config response = Ok sample_config in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok cfg) ->
    Alcotest.(check string) "socket" sample_config.socket cfg.socket
  | _ -> Alcotest.fail "json resp config"

let test_json_resp_status () =
  let cmd = Status in
  let resp : status_info response = Ok sample_status in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok si) ->
    Alcotest.(check int) "uptime" 3600 si.uptime_seconds
  | _ -> Alcotest.fail "json resp status"

let test_json_resp_err () =
  let cmd = Register in
  let resp : unit response = Error "bad request" in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Error msg) ->
    Alcotest.(check string) "msg" "bad request" msg
  | _ -> Alcotest.fail "json resp err"

let test_json_resp_set_config () =
  let cmd = Set_config sample_config in
  let resp : unit response = Ok () in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok ()) -> ()
  | _ -> Alcotest.fail "json resp set_config"

let test_json_resp_add_rule () =
  let cmd = Add_rule sample_rule in
  let resp : unit response = Ok () in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok ()) -> ()
  | _ -> Alcotest.fail "json resp add_rule"

let test_json_resp_update_rule () =
  let cmd = Update_rule (1, sample_rule) in
  let resp : unit response = Ok () in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok ()) -> ()
  | _ -> Alcotest.fail "json resp update_rule"

let test_json_resp_delete_rule () =
  let cmd = Delete_rule 1 in
  let resp : unit response = Ok () in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok ()) -> ()
  | _ -> Alcotest.fail "json resp delete_rule"

let test_json_resp_open_on () =
  let cmd = Open_on ("work", "https://x.com") in
  let resp : route_result response = Ok (Remote "work") in
  let json = serialize_response_json cmd resp in
  match deserialize_response_json cmd json with
  | Ok (Ok (Remote tid)) ->
    Alcotest.(check string) "tenant" "work" tid
  | _ -> Alcotest.fail "json resp open_on"

(* ── JSON round-trip: server push ────────────────────────────────── *)

let test_json_push_bridge () =
  let msg = Push (Push (Navigate "https://example.com")) in
  let json = bridge_message_to_yojson msg in
  match bridge_message_of_yojson json with
  | Ok (Push (Push (Navigate url))) ->
    Alcotest.(check string) "url" "https://example.com" url
  | _ -> Alcotest.fail "json bridge push"

let test_json_bridge_response () =
  let data = `Assoc [ ("status", `String "ok") ] in
  let msg = Response data in
  let json = bridge_message_to_yojson msg in
  match bridge_message_of_yojson json with
  | Ok (Response d) ->
    Alcotest.(check string) "json"
      (Yojson.Safe.to_string data)
      (Yojson.Safe.to_string d)
  | _ -> Alcotest.fail "json bridge response"

(* ── Run all tests ───────────────────────────────────────────────── *)

let () =
  Alcotest.run "protocol"
    [
      ( "line-commands",
        [
          Alcotest.test_case "register" `Quick test_line_rt_register;
          Alcotest.test_case "open" `Quick test_line_rt_open;
          Alcotest.test_case "open-spaces" `Quick
            test_line_rt_open_url_with_spaces;
          Alcotest.test_case "open_on" `Quick test_line_rt_open_on;
          Alcotest.test_case "test" `Quick test_line_rt_test;
          Alcotest.test_case "get_config" `Quick test_line_rt_get_config;
          Alcotest.test_case "set_config" `Quick test_line_rt_set_config;
          Alcotest.test_case "add_rule" `Quick test_line_rt_add_rule;
          Alcotest.test_case "update_rule" `Quick test_line_rt_update_rule;
          Alcotest.test_case "delete_rule" `Quick test_line_rt_delete_rule;
          Alcotest.test_case "status" `Quick test_line_rt_status;
        ] );
      ( "line-responses",
        [
          Alcotest.test_case "ok" `Quick test_line_resp_ok;
          Alcotest.test_case "local" `Quick test_line_resp_local;
          Alcotest.test_case "remote" `Quick test_line_resp_remote;
          Alcotest.test_case "remote-open_on" `Quick
            test_line_resp_remote_open_on;
          Alcotest.test_case "match" `Quick test_line_resp_match;
          Alcotest.test_case "nomatch" `Quick test_line_resp_nomatch;
          Alcotest.test_case "config" `Quick test_line_resp_config;
          Alcotest.test_case "status" `Quick test_line_resp_status;
          Alcotest.test_case "err" `Quick test_line_resp_err;
          Alcotest.test_case "err-special" `Quick
            test_line_resp_err_special_chars;
        ] );
      ( "line-push",
        [
          Alcotest.test_case "navigate" `Quick test_line_push_navigate;
          Alcotest.test_case "navigate-spaces" `Quick
            test_line_push_navigate_spaces;
        ] );
      ( "json-commands",
        [
          Alcotest.test_case "register" `Quick test_json_cmd_register;
          Alcotest.test_case "open" `Quick test_json_cmd_open;
          Alcotest.test_case "open_on" `Quick test_json_cmd_open_on;
          Alcotest.test_case "test" `Quick test_json_cmd_test;
          Alcotest.test_case "get_config" `Quick test_json_cmd_get_config;
          Alcotest.test_case "set_config" `Quick test_json_cmd_set_config;
          Alcotest.test_case "add_rule" `Quick test_json_cmd_add_rule;
          Alcotest.test_case "update_rule" `Quick test_json_cmd_update_rule;
          Alcotest.test_case "delete_rule" `Quick test_json_cmd_delete_rule;
          Alcotest.test_case "status" `Quick test_json_cmd_status;
        ] );
      ( "json-responses",
        [
          Alcotest.test_case "ok" `Quick test_json_resp_ok;
          Alcotest.test_case "local" `Quick test_json_resp_local;
          Alcotest.test_case "remote" `Quick test_json_resp_remote;
          Alcotest.test_case "match" `Quick test_json_resp_match;
          Alcotest.test_case "nomatch" `Quick test_json_resp_nomatch;
          Alcotest.test_case "config" `Quick test_json_resp_config;
          Alcotest.test_case "status" `Quick test_json_resp_status;
          Alcotest.test_case "err" `Quick test_json_resp_err;
          Alcotest.test_case "set_config" `Quick test_json_resp_set_config;
          Alcotest.test_case "add_rule" `Quick test_json_resp_add_rule;
          Alcotest.test_case "update_rule" `Quick test_json_resp_update_rule;
          Alcotest.test_case "delete_rule" `Quick test_json_resp_delete_rule;
          Alcotest.test_case "open_on" `Quick test_json_resp_open_on;
        ] );
      ( "json-push",
        [
          Alcotest.test_case "bridge-push" `Quick test_json_push_bridge;
          Alcotest.test_case "bridge-response" `Quick
            test_json_bridge_response;
        ] );
    ]
