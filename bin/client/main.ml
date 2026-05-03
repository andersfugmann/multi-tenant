open! Base
open! Stdio

(* -- Socket path *)

let socket_path () =
  match Sys.getenv "ALLOY_SOCKET" with
  | Some path -> path
  | None -> Protocol.default_socket_path ()

(* -- CLI argument parsing *)

type cli_mode =
  | Cli_command of Protocol.packed_command
  | Bridge
  | Register_stream

type cli_options = {
  mode : cli_mode;
  socket : string option;
  name : string option;
}

let parse_rule_json json_str =
  match
    Result.bind (Protocol.parse_json_string json_str) ~f:Protocol.rule_of_yojson
  with
  | Ok rule -> rule
  | Error msg -> failwith (Printf.sprintf "invalid rule JSON: %s" msg)

let parse_config_file json_file =
  let content = In_channel.read_all json_file in
  match
    Result.bind (Protocol.parse_json_string content) ~f:Protocol.config_of_yojson
  with
  | Ok cfg -> cfg
  | Error msg -> failwith (Printf.sprintf "invalid config JSON: %s" msg)

let parse_index idx_str =
  match Int.of_string_opt idx_str with
  | Some i -> i
  | None -> failwith (Printf.sprintf "invalid index: %s" idx_str)

let cli_term () =
  let open Cmdliner in
  let socket_opt =
    let doc = "Override daemon socket path." in
    Arg.(value & opt (some string) None
         & info [ "socket"; "s" ] ~docv:"PATH" ~doc)
  in
  let name_opt =
    let doc = "Override tenant name." in
    Arg.(value & opt (some string) None
         & info [ "name"; "n" ] ~docv:"TENANT" ~doc)
  in
  let make_opts mode socket name = { mode; socket; name } in
  let bridge_cmd =
    let doc = "Run as native messaging bridge for the browser extension." in
    Cmd.v (Cmd.info "bridge" ~doc)
      Term.(const (make_opts Bridge) $ socket_opt $ name_opt)
  in
  let register_cmd =
    let doc = "Register as a tenant and stream push messages." in
    Cmd.v (Cmd.info "register" ~doc)
      Term.(const (make_opts Register_stream) $ socket_opt $ name_opt)
  in
  let open_cmd =
    let doc = "Open a URL via the routing daemon." in
    let url =
      Arg.(required & pos 0 (some string) None
           & info [] ~docv:"URL" ~doc:"URL to open.")
    in
    Cmd.v (Cmd.info "open" ~doc)
      Term.(const (fun url -> make_opts (Cli_command (Command (Open url))))
            $ url $ socket_opt $ name_opt)
  in
  let open_on_cmd =
    let doc = "Open a URL on a specific tenant." in
    let target =
      Arg.(required & pos 0 (some string) None
           & info [] ~docv:"TARGET" ~doc:"Target tenant.")
    in
    let url =
      Arg.(required & pos 1 (some string) None
           & info [] ~docv:"URL" ~doc:"URL to open.")
    in
    Cmd.v (Cmd.info "open-on" ~doc)
      Term.(const (fun target url ->
              make_opts (Cli_command (Command (Open_on (target, url)))))
            $ target $ url $ socket_opt $ name_opt)
  in
  let test_cmd =
    let doc = "Test which tenant a URL would route to." in
    let url =
      Arg.(required & pos 0 (some string) None
           & info [] ~docv:"URL" ~doc:"URL to test.")
    in
    Cmd.v (Cmd.info "test" ~doc)
      Term.(const (fun url -> make_opts (Cli_command (Command (Test url))))
            $ url $ socket_opt $ name_opt)
  in
  let get_config_cmd =
    let doc = "Get the current daemon configuration." in
    Cmd.v (Cmd.info "get-config" ~doc)
      Term.(const (make_opts (Cli_command (Command Get_config)))
            $ socket_opt $ name_opt)
  in
  let set_config_cmd =
    let doc = "Set the daemon configuration from a JSON file." in
    let json_file =
      Arg.(required & pos 0 (some string) None
           & info [] ~docv:"FILE" ~doc:"Path to JSON config file.")
    in
    Cmd.v (Cmd.info "set-config" ~doc)
      Term.(const (fun json_file ->
              make_opts (Cli_command (Command (Set_config (parse_config_file json_file)))))
            $ json_file $ socket_opt $ name_opt)
  in
  let add_rule_cmd =
    let doc = "Add a routing rule (JSON)." in
    let json_str =
      Arg.(required & pos 0 (some string) None
           & info [] ~docv:"JSON" ~doc:"Rule as JSON string.")
    in
    Cmd.v (Cmd.info "add-rule" ~doc)
      Term.(const (fun json_str ->
              make_opts (Cli_command (Command (Add_rule (parse_rule_json json_str)))))
            $ json_str $ socket_opt $ name_opt)
  in
  let update_rule_cmd =
    let doc = "Update a routing rule at the given index." in
    let idx =
      Arg.(required & pos 0 (some string) None
           & info [] ~docv:"INDEX" ~doc:"Rule index (0-based).")
    in
    let json_str =
      Arg.(required & pos 1 (some string) None
           & info [] ~docv:"JSON" ~doc:"Rule as JSON string.")
    in
    Cmd.v (Cmd.info "update-rule" ~doc)
      Term.(const (fun idx_str json_str ->
              make_opts (Cli_command (Command (Update_rule (parse_index idx_str, parse_rule_json json_str)))))
            $ idx $ json_str $ socket_opt $ name_opt)
  in
  let delete_rule_cmd =
    let doc = "Delete a routing rule at the given index." in
    let idx =
      Arg.(required & pos 0 (some string) None
           & info [] ~docv:"INDEX" ~doc:"Rule index (0-based).")
    in
    Cmd.v (Cmd.info "delete-rule" ~doc)
      Term.(const (fun idx_str ->
              make_opts (Cli_command (Command (Delete_rule (parse_index idx_str)))))
            $ idx $ socket_opt $ name_opt)
  in
  let status_cmd =
    let doc = "Show daemon status." in
    Cmd.v (Cmd.info "status" ~doc)
      Term.(const (make_opts (Cli_command (Command Status)))
            $ socket_opt $ name_opt)
  in
  Cmd.group (Cmd.info "alloy" ~doc:"Alloy URL routing client")
    [ bridge_cmd; register_cmd; open_cmd; open_on_cmd; test_cmd;
      get_config_cmd; set_config_cmd; add_rule_cmd; update_rule_cmd;
      delete_rule_cmd; status_cmd ]

(* Format response as human-readable CLI output *)

let format_response : type a. a Protocol.command -> (a, string) Result.t -> string = fun cmd resp ->
  match cmd, resp with
  | _, Error msg -> Printf.sprintf "Error: %s" msg
  | Protocol.Register _, Ok () -> "OK"
  | Protocol.Open _, Ok Local -> "Local"
  | Protocol.Open_on _, Ok Local -> "Local"
  | Protocol.Open _, Ok Remote tid -> Printf.sprintf "Remote: %s" tid
  | Protocol.Open_on _, Ok Remote tid -> Printf.sprintf "Remote: %s" tid
  | Protocol.Test _, Ok Match { tenant; rule_index } ->
    Printf.sprintf "Match: tenant=%s rule=%d" tenant rule_index
  | Protocol.Test _, Ok No_match { default_tenant } ->
    Printf.sprintf "No match: default=%s" default_tenant
  | Protocol.Get_config, Ok value ->
    Yojson.Safe.pretty_to_string (Protocol.config_to_yojson value)
  | Protocol.Set_config _, Ok () -> "OK"
  | Protocol.Add_rule _, Ok () -> "OK"
  | Protocol.Update_rule _, Ok () -> "OK"
  | Protocol.Delete_rule _, Ok () -> "OK"
  | Protocol.Status, Ok info ->
    Printf.sprintf "Tenants: %s\nUptime: %ds"
      (String.concat ~sep:", " info.registered_tenants)
      info.uptime_seconds

(* -- Send a command to the daemon and get a response (CLI) *)

let send_command_cli :
    type a.
    net:_ Eio.Net.ty Eio.Resource.t ->
    tenant:string ->
    sock_path:string ->
    a Protocol.command ->
    string =
 fun ~net ~tenant ~sock_path cmd ->
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

let run_register ~net ~sock_path ~tenant =
  Eio.Switch.run @@ fun sw ->
  let flow =
    Eio.Net.connect ~sw net (`Unix sock_path)
  in
  let server_cmd : unit Protocol.server_command =
    { tenant; command = Register None }
  in
  let line = Protocol.serialize_server_command server_cmd in
  Eio.Flow.copy_string (line ^ "\n") flow;
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let first_line = Eio.Buf_read.line reader in
  (match Protocol.deserialize_response (Register None) first_line with
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
    sock_path:string ->
    a Protocol.command ->
    Protocol.Wire.response =
 fun ~net ~tenant ~sock_path cmd ->
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

let bridge_command_fiber ~net ~tenant ~sock_path ~stdin_flow
    ~(write_out : Yojson.Safe.t -> unit) : unit =
  let rec loop () =
    match read_native_message stdin_flow with
    | None -> ()
    | Some json ->
      let wire_response =
        match Protocol.deserialize_command_json json with
        | Error msg -> Protocol.Wire.Err { message = msg }
        | Ok (Command cmd) -> bridge_send_command ~net ~tenant ~sock_path cmd
      in
      let bridge_msg = Protocol.Wire.(bridge_message_to_yojson (Response wire_response)) in
      write_out bridge_msg;
      loop ()
  in
  loop ()

(* -- Bridge: push fiber (connect once, no retry) *)

let bridge_push_fiber ~net ~tenant ~brand ~sock_path
    ~(write_out : Yojson.Safe.t -> unit)
    ~(on_registered : unit -> unit) : unit =
  match
    Eio.Switch.run @@ fun sw ->
    let flow =
      Eio.Net.connect ~sw net (`Unix sock_path)
    in
    let server_cmd : unit Protocol.server_command =
      { tenant; command = Register brand }
    in
    let line = Protocol.serialize_server_command server_cmd in
    Eio.Flow.copy_string (line ^ "\n") flow;
    let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
    let first_line = Eio.Buf_read.line reader in
    (match Protocol.deserialize_response (Register brand) first_line with
     | Ok () -> on_registered ()
     | Error _msg -> on_registered ());
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
  | exception _exn -> on_registered ()

(* -- Bridge mode entry point *)

let run_bridge env =
  let net = Eio.Stdenv.net env in
  let default_tenant = Unix.gethostname () in
  let stdout_mutex = Eio.Mutex.create () in
  let stdout_flow = Eio.Stdenv.stdout env in
  let stdin_flow = Eio.Stdenv.stdin env in
  let write_out json =
    Eio.Mutex.use_rw ~protect:true stdout_mutex (fun () ->
        write_native_message stdout_flow json)
  in
  (* Read first message from extension: Register with brand and optional overrides *)
  let (brand, tenant, sock_override) =
    match read_native_message stdin_flow with
    | Some json ->
      (match Protocol.Wire.command_of_yojson json with
       | Ok (Register { brand; socket; name }) ->
         let resp = Protocol.bridge_response_to_yojson (Register brand) (Ok ()) in
         write_out resp;
         let tenant = Option.value name ~default:default_tenant in
         (brand, tenant, socket)
       | _ ->
         let resp = Protocol.Wire.(bridge_message_to_yojson
           (Response (Err { message = "expected Register as first message" }))) in
         write_out resp;
         (None, default_tenant, None))
    | None -> (None, default_tenant, None)
  in
  let sock_path = Option.value sock_override ~default:(socket_path ()) in
  let (registered, resolve_registered) = Eio.Promise.create () in
  let resolve_once =
    let resolved = ref false in
    fun () ->
      match !resolved with
      | true -> ()
      | false ->
        resolved := true;
        Eio.Promise.resolve resolve_registered ()
  in
  Eio.Fiber.both
    (fun () ->
      Eio.Promise.await registered;
      bridge_command_fiber ~net ~tenant ~sock_path
        ~stdin_flow
        ~write_out)
    (fun () ->
      bridge_push_fiber ~net ~tenant ~brand ~sock_path
        ~write_out
        ~on_registered:resolve_once)

(* -- Main *)

let run_cli { mode; socket; name } =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let resolve_socket () =
    match socket with
    | Some s -> s
    | None -> socket_path ()
  in
  let resolve_tenant default =
    match name with
    | Some n -> n
    | None -> default
  in
  match mode with
  | Bridge -> run_bridge env
  | Register_stream ->
    run_register ~net ~sock_path:(resolve_socket ()) ~tenant:(resolve_tenant (Unix.gethostname ()))
  | Cli_command (Command cmd) ->
    let tenant = resolve_tenant "default" in
    let output = send_command_cli ~net ~tenant ~sock_path:(resolve_socket ()) cmd in
    print_endline output

let () =
  let argv = Sys.get_argv () in
  (* Chromium launches native messaging hosts with a chrome-extension:// origin arg *)
  match Array.length argv with
  | 2 when String.is_prefix (Array.get argv 1) ~prefix:"chrome-extension://" ->
    run_cli { mode = Bridge; socket = None; name = None }
  | _ ->
    (match Cmdliner.Cmd.eval_value (cli_term ()) with
     | Ok (`Ok opts) -> run_cli opts
     | Ok `Help | Ok `Version -> ()
     | Error _ -> Stdlib.exit 1)
