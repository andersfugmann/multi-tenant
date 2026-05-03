open Base
open Stdio

let default_socket_path () =
  "/run/user/" ^ Int.to_string (Unix.getuid ()) ^ "/alloy.sock"

(* -- State *)

type cooldown_entry = { key : string; expires : float }

type pending_delivery = {
  url : string;
  target : string;
  reply : (Protocol.route_result, string) Result.t Eio.Promise.u;
}

type starting_tenant = {
  pending : pending_delivery list;
}

type compiled_rule = {
  rule : Protocol.rule;
  regex : Re.re;
}

type state = {
  config : Protocol.config;
  config_path : string;
  compiled_rules : compiled_rule list;
  registry : string Eio.Stream.t Map.M(String).t;
  starting : (string * starting_tenant) list;
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
      brand : string option;
      push_stream : string Eio.Stream.t;
      reply : (unit, string) Result.t Eio.Promise.u;
    }
  | Unregister_tenant of { tenant : string }
  | Launch_timeout of { tenant : string }

let default_config () : Protocol.config =
  {
    socket = default_socket_path ();
    tenants = [];
    rules = [];
    defaults =
      { unmatched = "local"; cooldown_seconds = 5; browser_launch_timeout = 10 };
  }

(* -- Config loading / saving *)

let browser_cmd_of_brand brand =
  Option.bind brand ~f:(fun raw ->
      match String.lowercase raw with
      | b when String.is_substring b ~substring:"edge" -> Some "microsoft-edge"
      | b when String.is_substring b ~substring:"chromium" -> Some "chromium"
      | b when String.is_substring b ~substring:"chrome" -> Some "chrome"
      | _ -> None)

let rec mkdir_p path =
  match Stdlib.Sys.file_exists path with
  | true -> ()
  | false ->
    mkdir_p (Stdlib.Filename.dirname path);
    (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let save_config_to_path config_path config =
  mkdir_p (Stdlib.Filename.dirname config_path);
  let json = Protocol.config_to_yojson config in
  let content = Yojson.Safe.pretty_to_string json in
  Out_channel.write_all config_path ~data:(content ^ "\n")

let load_config path =
  match Stdlib.Sys.file_exists path with
  | true ->
    let content = In_channel.read_all path in
    Result.bind (Protocol.parse_json_string content) ~f:(fun json ->
        Protocol.config_of_yojson json)
  | false ->
    let config = default_config () in
    printf "[alloy] no config found, creating default at %s\n%!" path;
    (try
       save_config_to_path path config
     with exn ->
       printf "[alloy] warning: could not write default config: %s\n%!"
         (Exn.to_string exn));
    Ok config

(* -- Rule evaluation *)

let compile_regex pattern =
  match Re.compile (Re.Pcre.re pattern) with
  | regex -> Ok regex
  | exception exn ->
    Error (Printf.sprintf "invalid regex '%s': %s" pattern (Exn.to_string exn))

let compile_rule (rule : Protocol.rule) =
  compile_regex rule.pattern
  |> Result.map ~f:(fun regex -> { rule; regex })

let compile_rules rules =
  List.map rules ~f:compile_rule
  |> Result.all

let find_matching_rule compiled_rules url =
  List.find_mapi ~f:(fun i cr ->
      match cr.rule.enabled && Re.execp cr.regex url with
      | true -> Some (cr.rule.target, i)
      | false -> None
    ) compiled_rules

(* -- Cooldown *)

let cooldown_key tenant url =
  Printf.sprintf "%s:%s" tenant url

let check_and_prune_cooldowns cooldowns ~now ~key =
  let rec loop acc = function
    | [] -> (false, List.rev acc)
    | entry :: _ when Float.(entry.expires < now) ->
      (false, List.rev acc)
    | entry :: rest when String.equal entry.key key ->
      (true, List.rev_append (entry :: acc) rest)
    | entry :: rest ->
      loop (entry :: acc) rest
  in
  loop [] cooldowns

(* -- Launch browser process (fire-and-forget) *)

let launch_browser cmd =
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0o000 in
  let args = String.split ~on:' ' cmd |> Array.of_list in
  let pid = Unix.create_process args.(0) args dev_null dev_null dev_null in
  Unix.close dev_null;
  printf "[alloy] launched browser (pid %d): %s\n%!" pid cmd

(* -- Deliver URL to tenant (idempotent, may defer) *)

let deliver_url state target url ~sw ~clock ~inbox =
  match Map.find state.registry target with
  | Some stream ->
    let push_line = Protocol.serialize_push (Navigate url) in
    Eio.Stream.add stream push_line;
    (state, Eio.Promise.create_resolved (Ok (Protocol.Remote target)))
  | None ->
    match List.Assoc.find state.starting ~equal:String.equal target with
    | Some sentinel ->
      (match List.exists sentinel.pending ~f:(fun pd -> String.equal pd.url url) with
       | true ->
         printf "[alloy] URL already queued for starting tenant %s: %s\n%!" target url;
         (state, Eio.Promise.create_resolved (Ok (Protocol.Remote target)))
       | false ->
         let (promise, resolver) = Eio.Promise.create () in
         let pending = { url; target; reply = resolver } :: sentinel.pending in
         let starting = List.Assoc.add state.starting ~equal:String.equal target { pending } in
         printf "[alloy] queued URL for starting tenant %s: %s\n%!" target url;
         ({ state with starting }, promise))
    | None ->
      let browser_cmd =
        List.Assoc.find state.config.tenants ~equal:String.equal target
        |> Option.bind ~f:(fun (tc : Protocol.tenant_config) -> tc.browser_cmd)
      in
      (match browser_cmd with
       | None ->
         let msg = Printf.sprintf "tenant %s not registered" target in
         (state, Eio.Promise.create_resolved (Error msg))
       | Some cmd ->
         let (promise, resolver) = Eio.Promise.create () in
         let sentinel = { pending = [ { url; target; reply = resolver } ] } in
         let starting = List.Assoc.add state.starting ~equal:String.equal target sentinel in
         launch_browser cmd;
         let timeout = Float.of_int state.config.defaults.browser_launch_timeout in
         Eio.Fiber.fork ~sw (fun () ->
           Eio.Time.sleep clock timeout;
           Eio.Stream.add inbox (Launch_timeout { tenant = target }));
         printf "[alloy] starting tenant %s (timeout %.0fs)\n%!" target timeout;
         ({ state with starting }, promise))

(* -- Command handlers *)

let handle_open state tenant url ~sw ~clock ~inbox =
  let target, _ =
    Option.value ~default:(state.config.defaults.unmatched, 0) (find_matching_rule state.compiled_rules url)
  in
  let now = Unix.gettimeofday () in
  let cooldown_key = cooldown_key tenant url in
  let (in_cooldown, pruned) = check_and_prune_cooldowns state.cooldowns ~now ~key:cooldown_key in
  let state = { state with cooldowns = pruned } in
  let target = match in_cooldown with
    | true -> "local"
    | false when String.equal target tenant -> "local"
    | false -> target
  in

  (* Only update the cooldowns if the target is not self *)
  let cooldowns = match target with
    | "local" -> state.cooldowns
    | _ ->
      let cooldown = Float.of_int state.config.defaults.cooldown_seconds in
      { key = cooldown_key; expires = now +. cooldown } :: state.cooldowns
  in
  let state = { state with cooldowns } in
  deliver_url state target url ~sw ~clock ~inbox

let handle_open_on state target url ~sw ~clock ~inbox =
  deliver_url state target url ~sw ~clock ~inbox

let handle_test state url =
  let result =
    match find_matching_rule state.compiled_rules url with
    | Some (target, idx) -> Protocol.Match { tenant = target; rule_index = idx }
    | None -> Protocol.No_match { default_tenant = state.config.defaults.unmatched }
  in
  (state, Ok result)

let handle_status state =
  let tenants = Map.keys state.registry in
  let uptime =
    Unix.gettimeofday () -. state.start_time |> Float.to_int
  in
  (state, Ok { Protocol.registered_tenants = tenants; uptime_seconds = uptime })

let handle_set_config state (cfg : Protocol.config) =
  match compile_rules cfg.rules with
  | Error msg -> (state, Error (Printf.sprintf "invalid rules: %s" msg))
  | Ok compiled_rules ->
    let state = { state with config = cfg; compiled_rules } in
    (try
       save_config_to_path state.config_path cfg;
       (state, Ok ())
     with exn ->
       (state, Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn))))

let handle_add_rule state (rule : Protocol.rule) =
  match compile_rule rule with
  | Error msg -> (state, Error msg)
  | Ok compiled ->
    let config = { state.config with rules = state.config.rules @ [ rule ] } in
    let compiled_rules = state.compiled_rules @ [ compiled ] in
    let state = { state with config; compiled_rules } in
    (try
       save_config_to_path state.config_path config;
       (state, Ok ())
     with exn ->
       (state, Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn))))

let handle_update_rule state idx (rule : Protocol.rule) =
  match compile_rule rule with
  | Error msg -> (state, Error msg)
  | Ok compiled ->
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
       let compiled_rules =
         List.mapi state.compiled_rules ~f:(fun i cr ->
             match Int.equal i idx with true -> compiled | false -> cr)
       in
       let config = { config with rules = new_rules } in
       let state = { state with config; compiled_rules } in
       (try
          save_config_to_path state.config_path config;
          (state, Ok ())
        with exn ->
          (state, Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn)))))

let handle_delete_rule state idx =
  let config = state.config in
  let len = List.length config.rules in
  match idx >= 0 && idx < len with
  | false ->
    (state, Error (Printf.sprintf "rule index %d out of range (0..%d)" idx (len - 1)))
  | true ->
    let new_rules =
      List.filteri config.rules ~f:(fun i _ -> not (Int.equal i idx))
    in
    let compiled_rules =
      List.filteri state.compiled_rules ~f:(fun i _ -> not (Int.equal i idx))
    in
    let config = { config with rules = new_rules } in
    let state = { state with config; compiled_rules } in
    (try
       save_config_to_path state.config_path config;
       (state, Ok ())
     with exn ->
       (state, Error (Printf.sprintf "failed to save config: %s" (Exn.to_string exn))))

(* -- Command dispatch *)

let resolve_reply reply tenant line response_line =
  printf "[alloy] req[%s]: %s\n[alloy] res[%s]: %s\n%!" tenant line tenant response_line;
  Eio.Promise.resolve reply response_line

let dispatch_command :
    type a. state -> Protocol.tenant_id -> a Protocol.command ->
    reply:string Eio.Promise.u -> line:string ->
    sw:Eio.Switch.t -> clock:_ Eio.Time.clock ->
    inbox:coordinator_msg Eio.Stream.t -> state =
 fun state tenant cmd ~reply ~line ~sw ~clock ~inbox ->
  match cmd with
  | Protocol.Register _ ->
    let resp = Protocol.serialize_response (Protocol.Register None)
        (Error "unexpected REGISTER in command mode") in
    resolve_reply reply tenant line resp;
    state
  | Protocol.Open url ->
    let (state, promise) = handle_open state tenant url ~sw ~clock ~inbox in
    Eio.Fiber.fork ~sw (fun () ->
      let result = Eio.Promise.await promise in
      let resp = Protocol.serialize_response (Open url) result in
      resolve_reply reply tenant line resp);
    state
  | Protocol.Open_on (target, url) ->
    let (state, promise) = handle_open_on state target url ~sw ~clock ~inbox in
    Eio.Fiber.fork ~sw (fun () ->
      let result = Eio.Promise.await promise in
      let resp = Protocol.serialize_response (Open_on (target, url)) result in
      resolve_reply reply tenant line resp);
    state
  | Protocol.Test url ->
    let (state, resp) = handle_test state url in
    resolve_reply reply tenant line (Protocol.serialize_response (Test url) resp);
    state
  | Protocol.Get_config ->
    resolve_reply reply tenant line (Protocol.serialize_response Get_config (Ok state.config));
    state
  | Protocol.Set_config cfg ->
    let (state, resp) = handle_set_config state cfg in
    resolve_reply reply tenant line (Protocol.serialize_response (Set_config cfg) resp);
    state
  | Protocol.Add_rule rule ->
    let (state, resp) = handle_add_rule state rule in
    resolve_reply reply tenant line (Protocol.serialize_response (Add_rule rule) resp);
    state
  | Protocol.Update_rule (idx, rule) ->
    let (state, resp) = handle_update_rule state idx rule in
    resolve_reply reply tenant line (Protocol.serialize_response (Update_rule (idx, rule)) resp);
    state
  | Protocol.Delete_rule idx ->
    let (state, resp) = handle_delete_rule state idx in
    resolve_reply reply tenant line (Protocol.serialize_response (Delete_rule idx) resp);
    state
  | Protocol.Status ->
    let (state, resp) = handle_status state in
    resolve_reply reply tenant line (Protocol.serialize_response Status resp);
    state

(* -- Coordinator loop *)

let dispatch_line state line ~reply ~sw ~clock ~inbox =
  match Protocol.deserialize_server_command line with
  | Error msg ->
    let resp = Printf.sprintf "ERR %s" msg in
    printf "[alloy] req: %s\n[alloy] res: %s\n%!" line resp;
    Eio.Promise.resolve reply resp;
    state
  | Ok (Server_command { tenant; command }) ->
    dispatch_command state tenant command ~reply ~line ~sw ~clock ~inbox

let rec coordinator_loop state inbox ~sw ~clock =
  let state = match Eio.Stream.take inbox with
    | Dispatch { line; reply } ->
      dispatch_line state line ~reply ~sw ~clock ~inbox
    | Register_tenant { tenant; brand; push_stream; reply } ->
      (match Map.mem state.registry tenant with
       | true ->
         Eio.Promise.resolve reply (Error "tenant already registered");
         printf "[alloy] tenant %s register rejected (already registered)\n%!" tenant;
         state
       | false ->
         let registry = Map.set state.registry ~key:tenant ~data:push_stream in
         Eio.Promise.resolve reply (Ok ());
         printf "[alloy] tenant %s registered (brand=%s)\n%!" tenant
           (Option.value brand ~default:"(none)");
         let state = { state with registry } in
         (* Flush pending deliveries if tenant was starting *)
         let state =
           match List.Assoc.find state.starting ~equal:String.equal tenant with
           | None -> state
           | Some sentinel ->
             List.iter sentinel.pending ~f:(fun pd ->
               let push_line = Protocol.serialize_push (Navigate pd.url) in
               Eio.Stream.add push_stream push_line;
               Eio.Promise.resolve pd.reply (Ok (Protocol.Remote tenant));
               printf "[alloy] delivered pending URL to %s: %s\n%!" tenant pd.url);
             let starting = List.Assoc.remove state.starting ~equal:String.equal tenant in
             { state with starting }
         in
         (* Update or auto-add tenant config with brand *)
         let suggested_cmd = browser_cmd_of_brand brand in
         let tenants =
           match List.Assoc.find state.config.tenants ~equal:String.equal tenant with
           | Some existing ->
             let browser_cmd =
               match existing.browser_cmd with
               | Some _ -> existing.browser_cmd
               | None -> suggested_cmd
             in
             let updated = { existing with brand; browser_cmd } in
             List.Assoc.add state.config.tenants ~equal:String.equal tenant updated
           | None ->
             let new_tenant : Protocol.tenant_config =
               { browser_cmd = suggested_cmd; label = tenant; color = "#808080"; brand }
             in
             printf "[alloy] auto-added tenant %s to config\n%!" tenant;
             state.config.tenants @ [ (tenant, new_tenant) ]
         in
         let config = { state.config with tenants } in
         (try save_config_to_path state.config_path config with _ -> ());
         { state with config })
    | Unregister_tenant { tenant } ->
      let registry = Map.remove state.registry tenant in
      printf "[alloy] tenant %s unregistered\n%!" tenant;
      { state with registry }
    | Launch_timeout { tenant } ->
      (match List.Assoc.find state.starting ~equal:String.equal tenant with
       | None -> state
       | Some sentinel ->
         List.iter sentinel.pending ~f:(fun pd ->
           let msg = Printf.sprintf "tenant %s failed to start within timeout" tenant in
           Eio.Promise.resolve pd.reply (Error msg);
           printf "[alloy] timeout: failed to deliver URL to %s: %s\n%!" tenant pd.url);
         let starting = List.Assoc.remove state.starting ~equal:String.equal tenant in
         printf "[alloy] tenant %s start timed out\n%!" tenant;
         { state with starting })
  in
  coordinator_loop state inbox ~sw ~clock

(* -- Registration (long-lived connection) *)

let handle_register inbox ~tenant ~brand flow reader =
  let push_stream = Eio.Stream.create 16 in
  let (promise, reply) = Eio.Promise.create () in
  Eio.Stream.add inbox (Register_tenant { tenant; brand; push_stream; reply });
  match Eio.Promise.await promise with
  | Error msg ->
    let err = Protocol.serialize_response (Register brand) (Error msg) in
    Eio.Flow.copy_string (err ^ "\n") flow
  | Ok () ->
    (match
       let ok = Protocol.serialize_response (Register brand) (Ok ()) in
       Eio.Flow.copy_string (ok ^ "\n") flow;
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

let handle_connection inbox flow =
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  match Eio.Buf_read.line reader with
  | exception (End_of_file | Eio.Io _) -> ()
  | line ->
    printf "[alloy] req: %s\n%!" line;
    (match Protocol.deserialize_server_command line with
     | Error msg ->
       let resp = Printf.sprintf "ERR %s" msg in
       printf "[alloy] res: %s\n%!" resp;
       Eio.Flow.copy_string (resp ^ "\n") flow
     | Ok (Server_command { tenant; command = Register brand }) ->
       printf "[alloy] res[%s]: registering (brand=%s)\n%!" tenant
         (Option.value brand ~default:"(none)");
       handle_register inbox ~tenant ~brand flow reader
     | Ok (Server_command _) ->
       let (promise, reply) = Eio.Promise.create () in
       Eio.Stream.add inbox (Dispatch { line; reply });
       let response_line = Eio.Promise.await promise in
       Eio.Flow.copy_string (response_line ^ "\n") flow)

(* -- Main *)

let () =
  Stdlib.Sys.set_signal Stdlib.Sys.sigchld Stdlib.Sys.Signal_ignore;
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  let config_path =
    let argv = Sys.get_argv () in
    match Array.length argv > 1 with
    | true -> argv.(1)
    | false ->
      let home = Sys.getenv_exn "HOME" in
      home ^ "/.config/alloy/config.json"
  in
  let config =
    match load_config config_path with
    | Ok c -> c
    | Error msg ->
      printf "[alloy] fatal: %s\n%!" msg;
      Stdlib.exit 1
  in
  let compiled_rules =
    match compile_rules config.rules with
    | Ok cr -> cr
    | Error msg ->
      printf "[alloy] fatal: invalid rules in config: %s\n%!" msg;
      Stdlib.exit 1
  in
  let initial_state =
    {
      config;
      config_path;
      compiled_rules;
      registry = Map.empty (module String);
      starting = [];
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
  printf "[alloy] listening on %s\n%!" socket_path;
  Eio.Fiber.all [
    (fun () -> coordinator_loop initial_state inbox ~sw ~clock);
    (fun () ->
      let rec accept_loop () =
        Eio.Net.accept_fork ~sw listening
          ~on_error:(fun exn ->
            printf "[alloy] connection error: %s\n%!"
              (Exn.to_string exn))
          (fun flow _addr -> handle_connection inbox flow);
        accept_loop ()
      in
      accept_loop ());
  ]
