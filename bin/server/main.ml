open Base
open Stdio

(* -- State *)

type cooldown_entry = { key : string; expires : float }

type state = {
  config : Protocol.config;
  config_path : string;
  registry : string Eio.Stream.t Map.M(String).t;
  cooldowns : cooldown_entry list;
  start_time : float;
}

(* -- Coordinator messages *)

type coordinator_msg =
  | Dispatch of {
      line : string;
      reply : string Eio.Promise.u;
    }
  | Register_tenant of {
      tenant : string;
      push_stream : string Eio.Stream.t;
      reply : (unit, string) Result.t Eio.Promise.u;
    }
  | Unregister_tenant of { tenant : string }
  | Update_config of Protocol.config

(* -- Config loading / saving *)

let load_config (path : string) : (Protocol.config, string) Result.t =
  match Stdlib.Sys.file_exists path with
  | false -> Error (Printf.sprintf "config file not found: %s" path)
  | true ->
    let content = In_channel.read_all path in
    Result.bind (Protocol.parse_json_string content) ~f:(fun json ->
        Protocol.config_of_yojson json)

let save_config_to_path (config_path : string) (config : Protocol.config) : unit =
  let json = Protocol.config_to_yojson config in
  let content = Yojson.Safe.pretty_to_string json in
  Out_channel.write_all config_path ~data:(content ^ "\n")

let config_mtime (path : string) : float option =
  match Unix.stat path with
  | stat -> Some stat.Unix.st_mtime
  | exception Unix.Unix_error _ -> None

(* -- Config file watcher (polling) *)

let config_watcher config_path (inbox : coordinator_msg Eio.Stream.t) clock =
  let rec loop last_mtime =
    Eio.Time.sleep clock 2.0;
    let current_mtime = config_mtime config_path in
    (match Option.equal Float.equal last_mtime current_mtime with
     | true -> loop last_mtime
     | false ->
       (match load_config config_path with
        | Ok new_config ->
          Eio.Stream.add inbox (Update_config new_config);
          eprintf "[url-router] config reloaded\n%!"
        | Error msg ->
          eprintf "[url-router] config reload failed: %s\n%!" msg);
       loop current_mtime)
  in
  loop (config_mtime config_path)

(* -- Rule evaluation *)

let compile_regex (pattern : string) : (Re.re, string) Result.t =
  match Re.compile (Re.Pcre.re pattern) with
  | regex -> Ok regex
  | exception exn ->
    Error (Printf.sprintf "invalid regex '%s': %s" pattern (Exn.to_string exn))

let evaluate_rules (rules : Protocol.rule list) (url : string)
    (default : string) : string * int option =
  rules
  |> List.mapi ~f:(fun i rule -> (i, rule))
  |> List.find_map ~f:(fun (i, (rule : Protocol.rule)) ->
         match rule.enabled with
         | false -> None
         | true ->
           (match compile_regex rule.pattern with
            | Error msg ->
              eprintf "[url-router] rule %d: %s\n%!" i msg;
              None
            | Ok regex ->
              (match Re.execp regex url with
               | true -> Some (rule.target, Some i)
               | false -> None)))
  |> function
  | Some (target, idx) -> (target, idx)
  | None -> (default, None)

(* -- Cooldown *)

let cooldown_key (tenant : string) (url : string) : string =
  tenant ^ "\x00" ^ url

let check_and_prune_cooldowns (cooldowns : cooldown_entry list) ~now ~key :
    bool * cooldown_entry list =
  let rec go acc = function
    | [] -> (false, List.rev acc)
    | entry :: rest ->
      (match Float.( > ) entry.expires now with
       | false -> (false, List.rev acc)
       | true ->
         (match String.equal entry.key key with
          | true -> (true, List.rev_append (entry :: acc) rest)
          | false -> go (entry :: acc) rest))
  in
  go [] cooldowns

(* -- Push to tenant *)

let push_navigate (state : state) (target : string) (url : string) :
    (unit, string) Result.t =
  match Map.find state.registry target with
  | None -> Error (Printf.sprintf "tenant %s not registered" target)
  | Some stream ->
    let push_line = Protocol.serialize_push (Navigate url) in
    Eio.Stream.add stream push_line;
    Ok ()

(* -- Command handlers (pure state transformers) *)

let handle_open (state : state) (tenant : string) (url : string) :
    state * (Protocol.route_result, string) Result.t =
  let target, _idx =
    evaluate_rules state.config.rules url state.config.defaults.unmatched
  in
  match String.equal tenant "default" with
  | true ->
    (match push_navigate state target url with
     | Ok () -> (state, Ok (Remote target))
     | Error msg -> (state, Error msg))
  | false ->
    let now = Unix.gettimeofday () in
    let key = cooldown_key tenant url in
    let (found, pruned) = check_and_prune_cooldowns state.cooldowns ~now ~key in
    let state = { state with cooldowns = pruned } in
    (match found with
     | true -> (state, Ok Local)
     | false ->
       (match String.equal target tenant || String.equal target "local" with
        | true -> (state, Ok Local)
        | false ->
          (match push_navigate state target url with
           | Ok () ->
             let cooldown = Float.of_int state.config.defaults.cooldown_seconds in
             let state =
               { state with cooldowns = { key; expires = now +. cooldown } :: state.cooldowns }
             in
             (state, Ok (Remote target))
           | Error msg -> (state, Error msg))))

let handle_open_on (state : state) (target : string) (url : string) :
    state * (Protocol.route_result, string) Result.t =
  match push_navigate state target url with
  | Ok () -> (state, Ok (Remote target))
  | Error msg -> (state, Error msg)

let handle_test (state : state) (url : string) :
    state * (Protocol.test_result, string) Result.t =
  let target, idx =
    evaluate_rules state.config.rules url state.config.defaults.unmatched
  in
  match idx with
  | Some i -> (state, Ok (Match { tenant = target; rule_index = i }))
  | None -> (state, Ok (No_match { default_tenant = target }))

let handle_status (state : state) :
    state * (Protocol.status_info, string) Result.t =
  let tenants = Map.keys state.registry in
  let uptime =
    Unix.gettimeofday () -. state.start_time |> Float.to_int
  in
  (state, Ok { registered_tenants = tenants; uptime_seconds = uptime })

let handle_set_config (state : state) (cfg : Protocol.config) :
    state * (unit, string) Result.t =
  let state = { state with config = cfg } in
  (try
     save_config_to_path state.config_path cfg;
     (state, Ok ())
   with exn ->
     (state, Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn))))

let handle_add_rule (state : state) (rule : Protocol.rule) :
    state * (unit, string) Result.t =
  match compile_regex rule.pattern with
  | Error msg -> (state, Error msg)
  | Ok _ ->
    let config = { state.config with rules = state.config.rules @ [ rule ] } in
    let state = { state with config } in
    (try
       save_config_to_path state.config_path config;
       (state, Ok ())
     with exn ->
       (state, Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn))))

let handle_update_rule (state : state) (idx : int) (rule : Protocol.rule) :
    state * (unit, string) Result.t =
  match compile_regex rule.pattern with
  | Error msg -> (state, Error msg)
  | Ok _ ->
    let config = state.config in
    let len = List.length config.rules in
    (match idx >= 0 && idx < len with
     | false ->
       (state, Error (Printf.sprintf "rule index %d out of range (0..%d)" idx (len - 1)))
     | true ->
       let new_rules =
         List.mapi config.rules ~f:(fun i r ->
             match Int.equal i idx with true -> rule | false -> r)
       in
       let config = { config with rules = new_rules } in
       let state = { state with config } in
       (try
          save_config_to_path state.config_path config;
          (state, Ok ())
        with exn ->
          (state, Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn)))))

let handle_delete_rule (state : state) (idx : int) :
    state * (unit, string) Result.t =
  let config = state.config in
  let len = List.length config.rules in
  match idx >= 0 && idx < len with
  | false ->
    (state, Error (Printf.sprintf "rule index %d out of range (0..%d)" idx (len - 1)))
  | true ->
    let new_rules =
      List.filteri config.rules ~f:(fun i _ -> not (Int.equal i idx))
    in
    let config = { config with rules = new_rules } in
    let state = { state with config } in
    (try
       save_config_to_path state.config_path config;
       (state, Ok ())
     with exn ->
       (state, Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn))))

(* -- Command dispatch *)

let dispatch_command :
    type a. state -> Protocol.tenant_id -> a Protocol.command -> state * string =
 fun state tenant cmd ->
  let (state, response_line) =
    match cmd with
    | Protocol.Register ->
      (state, Protocol.serialize_response Protocol.Register
         (Error "unexpected REGISTER in command mode"))
    | Protocol.Open url ->
      let (state, resp) = handle_open state tenant url in
      (state, Protocol.serialize_response (Open url) resp)
    | Protocol.Open_on (target, url) ->
      let (state, resp) = handle_open_on state target url in
      (state, Protocol.serialize_response (Open_on (target, url)) resp)
    | Protocol.Test url ->
      let (state, resp) = handle_test state url in
      (state, Protocol.serialize_response (Test url) resp)
    | Protocol.Get_config ->
      (state, Protocol.serialize_response Get_config (Ok state.config))
    | Protocol.Set_config cfg ->
      let (state, resp) = handle_set_config state cfg in
      (state, Protocol.serialize_response (Set_config cfg) resp)
    | Protocol.Add_rule rule ->
      let (state, resp) = handle_add_rule state rule in
      (state, Protocol.serialize_response (Add_rule rule) resp)
    | Protocol.Update_rule (idx, rule) ->
      let (state, resp) = handle_update_rule state idx rule in
      (state, Protocol.serialize_response (Update_rule (idx, rule)) resp)
    | Protocol.Delete_rule idx ->
      let (state, resp) = handle_delete_rule state idx in
      (state, Protocol.serialize_response (Delete_rule idx) resp)
    | Protocol.Status ->
      let (state, resp) = handle_status state in
      (state, Protocol.serialize_response Status resp)
  in
  (state, response_line)

(* -- Coordinator loop *)

let dispatch_line (state : state) (line : string) : state * string =
  match Protocol.deserialize_server_command line with
  | Error msg -> (state, Printf.sprintf "ERR %s" msg)
  | Ok (Server_command { tenant; command }) ->
    dispatch_command state tenant command

let rec coordinator_loop (state : state) (inbox : coordinator_msg Eio.Stream.t) : unit =
  let msg = Eio.Stream.take inbox in
  let state =
    match msg with
    | Dispatch { line; reply } ->
      let (state, response_line) = dispatch_line state line in
      Eio.Promise.resolve reply response_line;
      state
    | Register_tenant { tenant; push_stream; reply } ->
      (match Map.mem state.registry tenant with
       | true ->
         Eio.Promise.resolve reply (Error "tenant already registered");
         state
       | false ->
         let registry = Map.set state.registry ~key:tenant ~data:push_stream in
         Eio.Promise.resolve reply (Ok ());
         eprintf "[url-router] tenant %s registered\n%!" tenant;
         { state with registry })
    | Unregister_tenant { tenant } ->
      let registry = Map.remove state.registry tenant in
      eprintf "[url-router] tenant %s unregistered\n%!" tenant;
      { state with registry }
    | Update_config config ->
      { state with config }
  in
  coordinator_loop state inbox

(* -- Registration (long-lived connection) *)

let handle_register (inbox : coordinator_msg Eio.Stream.t) tenant flow reader =
  let push_stream = Eio.Stream.create 16 in
  let (promise, reply) = Eio.Promise.create () in
  Eio.Stream.add inbox (Register_tenant { tenant; push_stream; reply });
  match Eio.Promise.await promise with
  | Error msg ->
    let err = Protocol.serialize_response Register (Error msg) in
    Eio.Flow.copy_string (err ^ "\n") flow
  | Ok () ->
    let ok = Protocol.serialize_response Register (Ok ()) in
    Eio.Flow.copy_string (ok ^ "\n") flow;
    (match
       Eio.Fiber.both
         (fun () ->
           let rec write_loop () =
             let msg = Eio.Stream.take push_stream in
             Eio.Flow.copy_string (msg ^ "\n") flow;
             write_loop ()
           in
           write_loop ())
         (fun () ->
           let rec drain () =
             ignore (Eio.Buf_read.line reader : string);
             drain ()
           in
           drain ())
     with
     | () -> ()
     | exception _ -> ());
    Eio.Stream.add inbox (Unregister_tenant { tenant })

(* -- Connection handling *)

let handle_connection (inbox : coordinator_msg Eio.Stream.t) flow =
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  match Eio.Buf_read.line reader with
  | exception (End_of_file | Eio.Io _) -> ()
  | line ->
    (match Protocol.deserialize_server_command line with
     | Error msg ->
       Eio.Flow.copy_string (Printf.sprintf "ERR %s\n" msg) flow
     | Ok (Server_command { tenant; command = Register }) ->
       handle_register inbox tenant flow reader
     | Ok (Server_command _) ->
       let (promise, reply) = Eio.Promise.create () in
       Eio.Stream.add inbox (Dispatch { line; reply });
       let response_line = Eio.Promise.await promise in
       Eio.Flow.copy_string (response_line ^ "\n") flow)

(* -- Main *)

let () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  let config_path =
    let argv = Sys.get_argv () in
    match Array.length argv > 1 with
    | true -> argv.(1)
    | false ->
      let home = Sys.getenv_exn "HOME" in
      home ^ "/.config/url-router/config.json"
  in
  let config =
    match load_config config_path with
    | Ok c -> c
    | Error msg ->
      eprintf "[url-router] fatal: %s\n%!" msg;
      Stdlib.exit 1
  in
  let initial_state =
    {
      config;
      config_path;
      registry = Map.empty (module String);
      cooldowns = [];
      start_time = Unix.gettimeofday ();
    }
  in
  let socket_path = config.socket in
  (try Unix.unlink socket_path with Unix.Unix_error _ -> ());
  let inbox = Eio.Stream.create 64 in
  Eio.Switch.run @@ fun sw ->
  let listening =
    Eio.Net.listen ~sw ~backlog:128 net (`Unix socket_path)
  in
  eprintf "[url-router] listening on %s\n%!" socket_path;
  Eio.Fiber.all [
    (fun () -> coordinator_loop initial_state inbox);
    (fun () -> config_watcher config_path inbox clock);
    (fun () ->
      let rec accept_loop () =
        Eio.Net.accept_fork ~sw listening
          ~on_error:(fun exn ->
            eprintf "[url-router] connection error: %s\n%!"
              (Exn.to_string exn))
          (fun flow _addr -> handle_connection inbox flow);
        accept_loop ()
      in
      accept_loop ());
  ]
