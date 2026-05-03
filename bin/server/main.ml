open Base
open Stdio

let default_socket_path () : string =
  "/run/user/" ^ Int.to_string (Unix.getuid ()) ^ "/url-router.sock"

let browser_cmd_of_brand (brand : string option) : string option =
  Option.bind brand ~f:(fun raw ->
    let b = String.lowercase raw in
    match String.is_substring b ~substring:"edge" with
    | true -> Some "microsoft-edge"
    | false ->
      match String.is_substring b ~substring:"chromium" with
      | true -> Some "chromium"
      | false ->
        match String.is_substring b ~substring:"chrome" with
        | true -> Some "chrome"
        | false -> None)

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

type state = {
  config : Protocol.config;
  config_path : string;
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
  | Update_config of Protocol.config
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

let rec mkdir_p (path : string) : unit =
  match Stdlib.Sys.file_exists path with
  | true -> ()
  | false ->
    mkdir_p (Stdlib.Filename.dirname path);
    (try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let save_config_to_path (config_path : string) (config : Protocol.config) : unit =
  mkdir_p (Stdlib.Filename.dirname config_path);
  let json = Protocol.config_to_yojson config in
  let content = Yojson.Safe.pretty_to_string json in
  Out_channel.write_all config_path ~data:(content ^ "\n")

let load_config (path : string) : (Protocol.config, string) Result.t =
  match Stdlib.Sys.file_exists path with
  | true ->
    let content = In_channel.read_all path in
    Result.bind (Protocol.parse_json_string content) ~f:(fun json ->
        Protocol.config_of_yojson json)
  | false ->
    let config = default_config () in
    printf "[url-router] no config found, creating default at %s\n%!" path;
    (try
       save_config_to_path path config
     with exn ->
       printf "[url-router] warning: could not write default config: %s\n%!"
         (Exn.to_string exn));
    Ok config

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
          printf "[url-router] config reloaded\n%!"
        | Error msg ->
          printf "[url-router] config reload failed: %s\n%!" msg);
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
              printf "[url-router] rule %d: %s\n%!" i msg;
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

(* -- Launch browser process (fire-and-forget) *)

let launch_browser (cmd : string) : unit =
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0o000 in
  let pid =
    Unix.create_process "/bin/sh" [| "/bin/sh"; "-c"; cmd |]
      dev_null dev_null dev_null
  in
  Unix.close dev_null;
  printf "[url-router] launched browser (pid %d): %s\n%!" pid cmd

(* -- Deliver URL to tenant (idempotent, may defer) *)

let deliver_url (state : state) (target : string) (url : string)
    ~(sw : Eio.Switch.t) ~(clock : _ Eio.Time.clock)
    ~(inbox : coordinator_msg Eio.Stream.t) :
    state * (Protocol.route_result, string) Result.t Eio.Promise.t =
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
         printf "[url-router] URL already queued for starting tenant %s: %s\n%!" target url;
         (state, Eio.Promise.create_resolved (Ok (Protocol.Remote target)))
       | false ->
         let (promise, resolver) = Eio.Promise.create () in
         let pending = { url; target; reply = resolver } :: sentinel.pending in
         let starting = List.Assoc.add state.starting ~equal:String.equal target { pending } in
         printf "[url-router] queued URL for starting tenant %s: %s\n%!" target url;
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
         printf "[url-router] starting tenant %s (timeout %.0fs)\n%!" target timeout;
         ({ state with starting }, promise))

(* -- Command handlers *)

let handle_open (state : state) (tenant : string) (url : string)
    ~sw ~clock ~inbox :
    state * (Protocol.route_result, string) Result.t Eio.Promise.t =
  let target, _idx =
    evaluate_rules state.config.rules url state.config.defaults.unmatched
  in
  match String.equal tenant "default" with
  | true ->
    deliver_url state target url ~sw ~clock ~inbox
  | false ->
    let now = Unix.gettimeofday () in
    let key = cooldown_key tenant url in
    let (found, pruned) = check_and_prune_cooldowns state.cooldowns ~now ~key in
    let state = { state with cooldowns = pruned } in
    (match found with
     | true -> (state, Eio.Promise.create_resolved (Ok Protocol.Local))
     | false ->
       (match String.equal target tenant || String.equal target "local" with
        | true -> (state, Eio.Promise.create_resolved (Ok Protocol.Local))
        | false ->
          let cooldown = Float.of_int state.config.defaults.cooldown_seconds in
          let state =
            { state with cooldowns = { key; expires = now +. cooldown } :: state.cooldowns }
          in
          deliver_url state target url ~sw ~clock ~inbox))

let handle_open_on (state : state) (target : string) (url : string)
    ~sw ~clock ~inbox :
    state * (Protocol.route_result, string) Result.t Eio.Promise.t =
  deliver_url state target url ~sw ~clock ~inbox

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

let resolve_reply (reply : string Eio.Promise.u)
    (tenant : string) (line : string)
    (response_line : string) : unit =
  printf "[url-router] req[%s]: %s\n[url-router] res[%s]: %s\n%!" tenant line tenant response_line;
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

let dispatch_line (state : state) (line : string) ~reply
    ~sw ~clock ~inbox : state =
  match Protocol.deserialize_server_command line with
  | Error msg ->
    let resp = Printf.sprintf "ERR %s" msg in
    printf "[url-router] req: %s\n[url-router] res: %s\n%!" line resp;
    Eio.Promise.resolve reply resp;
    state
  | Ok (Server_command { tenant; command }) ->
    dispatch_command state tenant command ~reply ~line ~sw ~clock ~inbox

let rec coordinator_loop (state : state) (inbox : coordinator_msg Eio.Stream.t)
    ~(sw : Eio.Switch.t) ~(clock : _ Eio.Time.clock) : unit =
  let msg = Eio.Stream.take inbox in
  let state =
    match msg with
    | Dispatch { line; reply } ->
      dispatch_line state line ~reply ~sw ~clock ~inbox
    | Register_tenant { tenant; brand; push_stream; reply } ->
      (match Map.mem state.registry tenant with
       | true ->
         Eio.Promise.resolve reply (Error "tenant already registered");
         printf "[url-router] tenant %s register rejected (already registered)\n%!" tenant;
         state
       | false ->
         let registry = Map.set state.registry ~key:tenant ~data:push_stream in
         Eio.Promise.resolve reply (Ok ());
         printf "[url-router] tenant %s registered (brand=%s)\n%!" tenant
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
               printf "[url-router] delivered pending URL to %s: %s\n%!" tenant pd.url);
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
             printf "[url-router] auto-added tenant %s to config\n%!" tenant;
             state.config.tenants @ [ (tenant, new_tenant) ]
         in
         let config = { state.config with tenants } in
         (try save_config_to_path state.config_path config with _ -> ());
         { state with config })
    | Unregister_tenant { tenant } ->
      let registry = Map.remove state.registry tenant in
      printf "[url-router] tenant %s unregistered\n%!" tenant;
      { state with registry }
    | Update_config config ->
      printf "[url-router] config reloaded from disk\n%!";
      { state with config }
    | Launch_timeout { tenant } ->
      (match List.Assoc.find state.starting ~equal:String.equal tenant with
       | None -> state
       | Some sentinel ->
         List.iter sentinel.pending ~f:(fun pd ->
           let msg = Printf.sprintf "tenant %s failed to start within timeout" tenant in
           Eio.Promise.resolve pd.reply (Error msg);
           printf "[url-router] timeout: failed to deliver URL to %s: %s\n%!" tenant pd.url);
         let starting = List.Assoc.remove state.starting ~equal:String.equal tenant in
         printf "[url-router] tenant %s start timed out\n%!" tenant;
         { state with starting })
  in
  coordinator_loop state inbox ~sw ~clock

(* -- Registration (long-lived connection) *)

let handle_register (inbox : coordinator_msg Eio.Stream.t) ~tenant ~brand flow reader =
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

let handle_connection (inbox : coordinator_msg Eio.Stream.t) flow =
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  match Eio.Buf_read.line reader with
  | exception (End_of_file | Eio.Io _) -> ()
  | line ->
    printf "[url-router] req: %s\n%!" line;
    (match Protocol.deserialize_server_command line with
     | Error msg ->
       let resp = Printf.sprintf "ERR %s" msg in
       printf "[url-router] res: %s\n%!" resp;
       Eio.Flow.copy_string (resp ^ "\n") flow
     | Ok (Server_command { tenant; command = Register brand }) ->
       printf "[url-router] res[%s]: registering (brand=%s)\n%!" tenant
         (Option.value brand ~default:"(none)");
       handle_register inbox ~tenant ~brand flow reader
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
      printf "[url-router] fatal: %s\n%!" msg;
      Stdlib.exit 1
  in
  let initial_state =
    {
      config;
      config_path;
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
  printf "[url-router] listening on %s\n%!" socket_path;
  Eio.Fiber.all [
    (fun () -> coordinator_loop initial_state inbox ~sw ~clock);
    (fun () -> config_watcher config_path inbox clock);
    (fun () ->
      let rec accept_loop () =
        Eio.Net.accept_fork ~sw listening
          ~on_error:(fun exn ->
            printf "[url-router] connection error: %s\n%!"
              (Exn.to_string exn))
          (fun flow _addr -> handle_connection inbox flow);
        accept_loop ()
      in
      accept_loop ());
  ]
