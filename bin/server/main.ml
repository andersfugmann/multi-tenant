open Base
open Stdio

(* ── State ─────────────────────────────────────────────────────────── *)

type state = {
  config : Protocol.config ref;
  config_path : string;
  registry : string Eio.Stream.t Map.M(String).t ref;
  cooldowns : float Map.M(String).t ref;
  start_time : float;
}

(* ── Config loading / saving ───────────────────────────────────────── *)

let load_config (path : string) : Protocol.config =
  let content = In_channel.read_all path in
  let json = Yojson.Safe.from_string content in
  match Protocol.config_of_yojson json with
  | Ok config -> config
  | Error msg -> failwith (Printf.sprintf "failed to parse config: %s" msg)

let save_config (state : state) : unit =
  let json = Protocol.config_to_yojson !(state.config) in
  let content = Yojson.Safe.pretty_to_string json in
  Out_channel.write_all state.config_path ~data:(content ^ "\n")

let config_mtime (path : string) : float option =
  match Unix.stat path with
  | stat -> Some stat.Unix.st_mtime
  | exception Unix.Unix_error _ -> None

(* ── Config file watcher (polling) ─────────────────────────────────── *)

let config_watcher state clock =
  let last_mtime = ref (config_mtime state.config_path) in
  let rec loop () =
    Eio.Time.sleep clock 2.0;
    let current_mtime = config_mtime state.config_path in
    (match Option.equal Float.equal !last_mtime current_mtime with
     | true -> ()
     | false ->
       last_mtime := current_mtime;
       (match
          (try Some (load_config state.config_path)
           with _ -> None)
        with
        | Some new_config ->
          state.config := new_config;
          eprintf "[url-router] config reloaded\n%!"
        | None ->
          eprintf "[url-router] config reload failed, keeping current\n%!"));
    loop ()
  in
  loop ()

(* ── Rule evaluation ───────────────────────────────────────────────── *)

let evaluate_rules (rules : Protocol.rule list) (url : string)
    (default : string) : string * int option =
  rules
  |> List.mapi ~f:(fun i rule -> (i, rule))
  |> List.find_map ~f:(fun (i, (rule : Protocol.rule)) ->
         match rule.enabled with
         | false -> None
         | true ->
           (match
              try Some (Re.compile (Re.Pcre.re rule.pattern))
              with _ -> None
            with
            | None -> None
            | Some regex ->
              (match Re.execp regex url with
               | true -> Some (rule.target, Some i)
               | false -> None)))
  |> function
  | Some (target, idx) -> (target, idx)
  | None -> (default, None)

(* ── Cooldown ──────────────────────────────────────────────────────── *)

let cooldown_key (tenant : string) (url : string) : string =
  tenant ^ "\x00" ^ url

let check_cooldown (state : state) (tenant : string) (url : string) : bool =
  let now = Unix.gettimeofday () in
  let key = cooldown_key tenant url in
  match Map.find !(state.cooldowns) key with
  | Some expiry -> Float.( > ) expiry now
  | None -> false

let record_cooldown (state : state) (tenant : string) (url : string) : unit =
  let now = Unix.gettimeofday () in
  let cooldown = Float.of_int !(state.config).defaults.cooldown_seconds in
  let key = cooldown_key tenant url in
  state.cooldowns := Map.set !(state.cooldowns) ~key ~data:(now +. cooldown)

let prune_cooldowns (state : state) : unit =
  let now = Unix.gettimeofday () in
  state.cooldowns :=
    Map.filter !(state.cooldowns) ~f:(fun expiry -> Float.( > ) expiry now)

(* ── Push to tenant ────────────────────────────────────────────────── *)

let push_navigate (state : state) (target : string) (url : string) :
    (unit, string) Result.t =
  match Map.find !(state.registry) target with
  | None -> Error (Printf.sprintf "tenant %s not registered" target)
  | Some stream ->
    let push_line = Protocol.serialize_push (Navigate url) in
    Eio.Stream.add stream push_line;
    Ok ()

(* ── Command handlers ──────────────────────────────────────────────── *)

let handle_open (state : state) (tenant : string) (url : string) :
    Protocol.route_result Protocol.response =
  let config = !(state.config) in
  let target, _idx =
    evaluate_rules config.rules url config.defaults.unmatched
  in
  match String.equal tenant "default" with
  | true ->
    (* CLI source: always push to resolved target *)
    (match push_navigate state target url with
     | Ok () -> Ok (Remote target)
     | Error msg -> Error msg)
  | false ->
    (* Browser extension source *)
    (match check_cooldown state tenant url with
     | true -> Ok Local
     | false ->
       (match
          String.equal target tenant || String.equal target "local"
        with
        | true -> Ok Local
        | false ->
          (match push_navigate state target url with
           | Ok () ->
             record_cooldown state tenant url;
             Ok (Remote target)
           | Error msg -> Error msg)))

let handle_open_on (state : state) (target : string) (url : string) :
    Protocol.route_result Protocol.response =
  match push_navigate state target url with
  | Ok () -> Ok (Remote target)
  | Error msg -> Error msg

let handle_test (state : state) (url : string) :
    Protocol.test_result Protocol.response =
  let config = !(state.config) in
  let target, idx =
    evaluate_rules config.rules url config.defaults.unmatched
  in
  match idx with
  | Some i -> Ok (Match { tenant = target; rule_index = i })
  | None -> Ok (No_match { default_tenant = target })

let handle_status (state : state) :
    Protocol.status_info Protocol.response =
  let tenants = Map.keys !(state.registry) in
  let uptime =
    Unix.gettimeofday () -. state.start_time |> Float.to_int
  in
  Ok { registered_tenants = tenants; uptime_seconds = uptime }

let handle_set_config (state : state) (cfg : Protocol.config) :
    unit Protocol.response =
  state.config := cfg;
  (try
     save_config state;
     Ok ()
   with exn ->
     Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn)))

let handle_add_rule (state : state) (rule : Protocol.rule) :
    unit Protocol.response =
  let config = !(state.config) in
  state.config := { config with rules = config.rules @ [ rule ] };
  (try
     save_config state;
     Ok ()
   with exn ->
     Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn)))

let handle_update_rule (state : state) (idx : int) (rule : Protocol.rule) :
    unit Protocol.response =
  let config = !(state.config) in
  let len = List.length config.rules in
  match idx >= 0 && idx < len with
  | false ->
    Error (Printf.sprintf "rule index %d out of range (0..%d)" idx (len - 1))
  | true ->
    let new_rules =
      List.mapi config.rules ~f:(fun i r ->
          match Int.equal i idx with true -> rule | false -> r)
    in
    state.config := { config with rules = new_rules };
    (try
       save_config state;
       Ok ()
     with exn ->
       Error
         (Printf.sprintf "failed to save config: %s" (Exn.to_string exn)))

let handle_delete_rule (state : state) (idx : int) :
    unit Protocol.response =
  let config = !(state.config) in
  let len = List.length config.rules in
  match idx >= 0 && idx < len with
  | false ->
    Error (Printf.sprintf "rule index %d out of range (0..%d)" idx (len - 1))
  | true ->
    let new_rules =
      List.filteri config.rules ~f:(fun i _ -> not (Int.equal i idx))
    in
    state.config := { config with rules = new_rules };
    (try
       save_config state;
       Ok ()
     with exn ->
       Error
         (Printf.sprintf "failed to save config: %s" (Exn.to_string exn)))

(* ── Command dispatch ──────────────────────────────────────────────── *)

let dispatch_command :
    type a. state -> Protocol.tenant_id -> a Protocol.command -> string =
 fun state tenant cmd ->
  let (response : a Protocol.response) =
    match cmd with
    | Protocol.Register -> Error "unexpected REGISTER in command mode"
    | Protocol.Open url -> handle_open state tenant url
    | Protocol.Open_on (target, url) -> handle_open_on state target url
    | Protocol.Test url -> handle_test state url
    | Protocol.Get_config -> Ok !(state.config)
    | Protocol.Set_config cfg -> handle_set_config state cfg
    | Protocol.Add_rule rule -> handle_add_rule state rule
    | Protocol.Update_rule (idx, rule) -> handle_update_rule state idx rule
    | Protocol.Delete_rule idx -> handle_delete_rule state idx
    | Protocol.Status -> handle_status state
  in
  Protocol.serialize_response cmd response

(* ── Registration (long-lived connection) ──────────────────────────── *)

let handle_register state tenant flow reader =
  match Map.mem !(state.registry) tenant with
  | true ->
    let err =
      Protocol.serialize_response Register
        (Error "tenant already registered")
    in
    Eio.Flow.copy_string (err ^ "\n") flow
  | false ->
    let stream = Eio.Stream.create 16 in
    state.registry := Map.set !(state.registry) ~key:tenant ~data:stream;
    let ok = Protocol.serialize_response Register (Ok ()) in
    Eio.Flow.copy_string (ok ^ "\n") flow;
    eprintf "[url-router] tenant %s registered\n%!" tenant;
    (try
       Eio.Fiber.both
         (fun () ->
           (* Writer: forward pushes from stream to socket *)
           let rec write_loop () =
             let msg = Eio.Stream.take stream in
             Eio.Flow.copy_string (msg ^ "\n") flow;
             write_loop ()
           in
           write_loop ())
         (fun () ->
           (* Reader: drain until disconnect *)
           let rec drain () =
             ignore (Eio.Buf_read.line reader : string);
             drain ()
           in
           drain ())
     with _ -> ());
    state.registry := Map.remove !(state.registry) tenant;
    eprintf "[url-router] tenant %s unregistered\n%!" tenant

(* ── Connection handling ───────────────────────────────────────────── *)

let handle_connection state flow =
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  match Eio.Buf_read.line reader with
  | exception (End_of_file | Eio.Io _) -> ()
  | line ->
    (match Protocol.deserialize_server_command line with
     | Error msg ->
       Eio.Flow.copy_string (Printf.sprintf "ERR %s\n" msg) flow
     | Ok (Server_command { tenant; command = Register }) ->
       handle_register state tenant flow reader
     | Ok (Server_command { tenant; command }) ->
       let response_line = dispatch_command state tenant command in
       Eio.Flow.copy_string (response_line ^ "\n") flow)

(* ── Main ──────────────────────────────────────────────────────────── *)

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
  let config = load_config config_path in
  let state =
    {
      config = ref config;
      config_path;
      registry = ref (Map.empty (module String));
      cooldowns = ref (Map.empty (module String));
      start_time = Unix.gettimeofday ();
    }
  in
  let socket_path = config.socket in
  (try Unix.unlink socket_path with Unix.Unix_error _ -> ());
  Eio.Switch.run @@ fun sw ->
  let listening =
    Eio.Net.listen ~sw ~backlog:128 net (`Unix socket_path)
  in
  eprintf "[url-router] listening on %s\n%!" socket_path;
  (* Periodically prune expired cooldowns *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec loop () =
        Eio.Time.sleep clock 30.0;
        prune_cooldowns state;
        loop ()
      in
      loop ());
  (* Run config watcher and accept loop concurrently *)
  Eio.Fiber.both
    (fun () -> config_watcher state clock)
    (fun () ->
      let rec accept_loop () =
        Eio.Net.accept_fork ~sw listening
          ~on_error:(fun exn ->
            eprintf "[url-router] connection error: %s\n%!"
              (Exn.to_string exn))
          (fun flow _addr -> handle_connection state flow);
        accept_loop ()
      in
      accept_loop ())
