open Base
open Stdio

(* -- Socket path *)

let socket_path () =
  match Sys.getenv "URL_ROUTER_SOCKET" with
  | Some path -> path
  | None ->
    "/run/user/" ^ Int.to_string (Unix.getuid ()) ^ "/url-router.sock"

(* -- Hostname detection *)

let hostname () = Unix.gethostname ()

(* -- CLI argument parsing *)

type cli_mode =
  | Cli_command of Protocol.packed_command
  | Bridge
  | Register_stream

let parse_cli (argv : string array) : cli_mode =
  let args = Array.to_list argv |> List.tl_exn in
  match args with
  | [ "--bridge" ] -> Bridge
  | "open" :: [ url ] -> Cli_command (Command (Open url))
  | "open-on" :: target :: [ url ] ->
    Cli_command (Command (Open_on (target, url)))
  | "test" :: [ url ] -> Cli_command (Command (Test url))
  | [ "get-config" ] -> Cli_command (Command Get_config)
  | "set-config" :: [ json_file ] ->
    let content = In_channel.read_all json_file in
    (match
       Result.bind (Protocol.parse_json_string content) ~f:Protocol.config_of_yojson
     with
     | Ok cfg -> Cli_command (Command (Set_config cfg))
     | Error msg -> failwith (Printf.sprintf "invalid config JSON: %s" msg))
  | "add-rule" :: [ json_str ] ->
    (match
       Result.bind (Protocol.parse_json_string json_str) ~f:Protocol.rule_of_yojson
     with
     | Ok rule -> Cli_command (Command (Add_rule rule))
     | Error msg -> failwith (Printf.sprintf "invalid rule JSON: %s" msg))
  | "update-rule" :: idx_str :: [ json_str ] ->
    let idx =
      match Int.of_string_opt idx_str with
      | Some i -> i
      | None -> failwith (Printf.sprintf "invalid index: %s" idx_str)
    in
    (match
       Result.bind (Protocol.parse_json_string json_str) ~f:Protocol.rule_of_yojson
     with
     | Ok rule -> Cli_command (Command (Update_rule (idx, rule)))
     | Error msg -> failwith (Printf.sprintf "invalid rule JSON: %s" msg))
  | "delete-rule" :: [ idx_str ] ->
    (match Int.of_string_opt idx_str with
     | Some idx -> Cli_command (Command (Delete_rule idx))
     | None -> failwith (Printf.sprintf "invalid index: %s" idx_str))
  | [ "status" ] -> Cli_command (Command Status)
  | [ "register" ] -> Register_stream
  | _ ->
    eprintf
      "Usage: url-router-client <command> [args]\n\
       Commands:\n\
      \  open <url>\n\
      \  open-on <target> <url>\n\
      \  test <url>\n\
      \  get-config\n\
      \  set-config <json-file>\n\
      \  add-rule <json>\n\
      \  update-rule <index> <json>\n\
      \  delete-rule <index>\n\
      \  status\n\
      \  register\n\
      \  --bridge\n";
    Stdlib.exit 1

(* Format response as human-readable CLI output *)

let format_response : type a. a Protocol.command -> (a, string) Result.t -> string =
 fun cmd resp ->
  match resp with
  | Error msg -> Printf.sprintf "Error: %s" msg
  | Ok value ->
    (match cmd with
     | Protocol.Register -> "OK"
     | Protocol.Open _ ->
       (match value with
        | Local -> "Local"
        | Remote tid -> Printf.sprintf "Remote: %s" tid)
     | Protocol.Open_on _ ->
       (match value with
        | Local -> "Local"
        | Remote tid -> Printf.sprintf "Remote: %s" tid)
     | Protocol.Test _ ->
       (match value with
        | Match { tenant; rule_index } ->
          Printf.sprintf "Match: tenant=%s rule=%d" tenant rule_index
        | No_match { default_tenant } ->
          Printf.sprintf "No match: default=%s" default_tenant)
     | Protocol.Get_config ->
       Yojson.Safe.pretty_to_string (Protocol.config_to_yojson value)
     | Protocol.Set_config _ -> "OK"
     | Protocol.Add_rule _ -> "OK"
     | Protocol.Update_rule _ -> "OK"
     | Protocol.Delete_rule _ -> "OK"
     | Protocol.Status ->
       let info = value in
       Printf.sprintf "Tenants: %s\nUptime: %ds"
         (String.concat ~sep:", " info.registered_tenants)
         info.uptime_seconds)

(* -- Send a command to the daemon and get a response (CLI) *)

let send_command_cli :
    type a.
    net:_ Eio.Net.ty Eio.Resource.t ->
    tenant:string ->
    a Protocol.command ->
    string =
 fun ~net ~tenant cmd ->
  let sock_path = socket_path () in
  Eio.Switch.run @@ fun sw ->
  let flow =
    Eio.Net.connect ~sw net (`Unix sock_path)
  in
  let server_cmd : a Protocol.server_command = { tenant; command = cmd } in
  let line = Protocol.serialize_server_command server_cmd in
  Eio.Flow.copy_string (line ^ "\n") flow;
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let response_line = Eio.Buf_read.line reader in
  Protocol.deserialize_response cmd response_line
  |> format_response cmd

(* -- CLI register: stay connected, print pushes *)

let run_register ~net =
  let sock_path = socket_path () in
  let tenant = hostname () in
  Eio.Switch.run @@ fun sw ->
  let flow =
    Eio.Net.connect ~sw net (`Unix sock_path)
  in
  let server_cmd : unit Protocol.server_command =
    { tenant; command = Register }
  in
  let line = Protocol.serialize_server_command server_cmd in
  Eio.Flow.copy_string (line ^ "\n") flow;
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let first_line = Eio.Buf_read.line reader in
  (match Protocol.deserialize_response Register first_line with
   | Ok () -> printf "Registered as %s\n%!" tenant
   | Error msg ->
     eprintf "Registration failed: %s\n%!" msg;
     Stdlib.exit 1);
  let rec read_loop () =
    match Eio.Buf_read.line reader with
    | push_line ->
      (match Protocol.deserialize_push push_line with
       | Ok (Push (Navigate url)) ->
         printf "NAVIGATE %s\n%!" url
       | Error msg ->
         eprintf "Push parse error: %s\n%!" msg);
      read_loop ()
    | exception End_of_file ->
      eprintf "Server disconnected\n%!"
    | exception Eio.Io _ ->
      eprintf "Server disconnected\n%!"
  in
  read_loop ()

(* -- Native messaging framing *)

let read_native_message source : Yojson.Safe.t option =
  let len_buf = Cstruct.create 4 in
  match Eio.Flow.read_exact source len_buf with
  | exception End_of_file -> None
  | exception Eio.Io _ -> None
  | () ->
    let len = Cstruct.LE.get_uint32 len_buf 0 |> Int32.to_int_exn in
    let data_buf = Cstruct.create len in
    (match Eio.Flow.read_exact source data_buf with
     | exception End_of_file -> None
     | exception Eio.Io _ -> None
     | () ->
       let s = Cstruct.to_string data_buf in
       (match Yojson.Safe.from_string s with
        | json -> Some json
        | exception Yojson.Json_error _ -> None))

let write_native_message sink (json : Yojson.Safe.t) : unit =
  let data = Yojson.Safe.to_string json in
  let len = String.length data in
  let len_buf = Cstruct.create 4 in
  Cstruct.LE.set_uint32 len_buf 0 (Int32.of_int_exn len);
  Eio.Flow.copy_string (Cstruct.to_string len_buf) sink;
  Eio.Flow.copy_string data sink

(* -- Bridge: send a command to daemon, return JSON response *)

let bridge_send_command :
    type a.
    net:_ Eio.Net.ty Eio.Resource.t ->
    tenant:string ->
    a Protocol.command ->
    Protocol.Wire.response =
 fun ~net ~tenant cmd ->
  let sock_path = socket_path () in
  match
    Eio.Switch.run @@ fun sw ->
    let flow =
      Eio.Net.connect ~sw net (`Unix sock_path)
    in
    let server_cmd : a Protocol.server_command = { tenant; command = cmd } in
    let line = Protocol.serialize_server_command server_cmd in
    Eio.Flow.copy_string (line ^ "\n") flow;
    let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
    let response_line = Eio.Buf_read.line reader in
    Protocol.deserialize_response cmd response_line
    |> Protocol.response_to_wire cmd
  with
  | wire -> wire
  | exception exn ->
    Protocol.Wire.Err { message = Exn.to_string exn }

(* -- Bridge: command fiber *)

let bridge_command_fiber ~net ~tenant ~stdin_flow
    ~(write_out : Yojson.Safe.t -> unit) : unit =
  let rec loop () =
    match read_native_message stdin_flow with
    | None -> ()
    | Some json ->
      let wire_response =
        match Protocol.deserialize_command_json json with
        | Error msg -> Protocol.Wire.Err { message = msg }
        | Ok (Command cmd) -> bridge_send_command ~net ~tenant cmd
      in
      let bridge_msg = Protocol.Wire.(bridge_message_to_yojson (Response wire_response)) in
      write_out bridge_msg;
      loop ()
  in
  loop ()

(* -- Bridge: push fiber (connect once, no retry) *)

let bridge_push_fiber ~net ~tenant
    ~(write_out : Yojson.Safe.t -> unit) : unit =
  let sock_path = socket_path () in
  match
    Eio.Switch.run @@ fun sw ->
    let flow =
      Eio.Net.connect ~sw net (`Unix sock_path)
    in
    let server_cmd : unit Protocol.server_command =
      { tenant; command = Register }
    in
    let line = Protocol.serialize_server_command server_cmd in
    Eio.Flow.copy_string (line ^ "\n") flow;
    let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
    let first_line = Eio.Buf_read.line reader in
    (match Protocol.deserialize_response Register first_line with
     | Ok () -> ()
     | Error _msg -> ());
    let rec read_loop () =
      let push_line = Eio.Buf_read.line reader in
      (match Protocol.deserialize_push push_line with
       | Ok push ->
         let msg = Protocol.bridge_push_to_yojson push in
         write_out msg
       | Error _msg -> ());
      read_loop ()
    in
    read_loop ()
  with
  | () -> ()
  | exception _exn -> ()

(* -- Bridge mode entry point *)

let run_bridge env =
  let net = Eio.Stdenv.net env in
  let tenant = hostname () in
  let stdout_mutex = Eio.Mutex.create () in
  let stdout_flow = Eio.Stdenv.stdout env in
  let stdin_flow = Eio.Stdenv.stdin env in
  let write_out json =
    Eio.Mutex.use_rw ~protect:true stdout_mutex (fun () ->
        write_native_message stdout_flow json)
  in
  Eio.Fiber.both
    (fun () ->
      bridge_command_fiber ~net ~tenant
        ~stdin_flow
        ~write_out)
    (fun () ->
      bridge_push_fiber ~net ~tenant
        ~write_out)

(* -- Detect if running as native messaging host *)

let is_terminal () = Unix.isatty Unix.stdin

(* -- Main *)

let () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let argv = Sys.get_argv () in
  (* Detect bridge mode: explicit --bridge flag or stdin is not a terminal *)
  let mode =
    match Array.length argv > 1 with
    | true -> parse_cli argv
    | false ->
      (match is_terminal () with
       | true -> parse_cli argv
       | false -> Bridge)
  in
  match mode with
  | Bridge -> run_bridge env
  | Register_stream -> run_register ~net
  | Cli_command (Command cmd) ->
    let tenant = "default" in
    let output = send_command_cli ~net ~tenant cmd in
    print_endline output
