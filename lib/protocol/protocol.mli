(** Multi-tenant URL routing protocol types and serialization. *)

(** {1 Core data types} *)

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

type config = {
  socket : string;
  tenants : (string * tenant_config) list;
  rules : rule list;
  defaults : defaults;
}
[@@deriving yojson]

type status_info = {
  registered_tenants : tenant_id list;
  uptime_seconds : int;
}
[@@deriving yojson]

(** {1 Response payload types} *)

type route_result =
  | Local
  | Remote of tenant_id
[@@deriving yojson]

type test_result =
  | Match of { tenant : tenant_id; rule_index : int }
  | No_match of { default_tenant : tenant_id }
[@@deriving yojson]

(** {1 GADT command type} *)

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

(** {1 Server push} *)

type _ server_push = Navigate : url -> url server_push

type packed_server_push = Push : 'a server_push -> packed_server_push

(** {1 Existential wrappers} *)

type packed_command = Command : 'a command -> packed_command

type 'a server_command = { tenant : tenant_id; command : 'a command }

type packed_server_command =
  | Server_command : 'a server_command -> packed_server_command

(** {1 Line protocol — server commands} *)

val serialize_server_command : 'a server_command -> string
val deserialize_server_command : string -> (packed_server_command, string) Result.t

(** {1 Line protocol -- responses} *)

val serialize_response : 'a command -> ('a, string) Result.t -> string
val deserialize_response : 'a command -> string -> ('a, string) Result.t

(** {1 Line protocol — server push} *)

val serialize_push : 'a server_push -> string
val deserialize_push : string -> (packed_server_push, string) Result.t

(** {1 JSON wire types} *)

module Wire : sig
  type command =
    | Register
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
    | Ok_route of route_result
    | Ok_test of test_result
    | Ok_config of config
    | Ok_status of status_info
    | Err of { message : string }
  [@@deriving yojson]

  type push = Navigate of { url : string } [@@deriving yojson]

  type bridge_message =
    | Response of response
    | Push of push
  [@@deriving yojson]
end

(** {1 Wire type conversions} *)

val command_to_wire : 'a command -> Wire.command
val command_of_wire : Wire.command -> packed_command
val response_to_wire : 'a command -> ('a, string) Result.t -> Wire.response
val response_of_wire : 'a command -> Wire.response -> ('a, string) Result.t

(** {1 JSON serialization -- commands} *)

val serialize_command_json : 'a command -> Yojson.Safe.t
val deserialize_command_json : Yojson.Safe.t -> (packed_command, string) Result.t

(** {1 JSON serialization -- responses} *)

val serialize_response_json : 'a command -> ('a, string) Result.t -> Yojson.Safe.t

val deserialize_response_json :
  'a command -> Yojson.Safe.t -> ('a, string) Result.t

(** {1 JSON helpers} *)

val parse_json_string : string -> (Yojson.Safe.t, string) Result.t

(** {1 Bridge message} *)

val bridge_response_to_yojson : 'a command -> ('a, string) Result.t -> Yojson.Safe.t
val bridge_push_to_yojson : packed_server_push -> Yojson.Safe.t
val bridge_message_of_yojson : Yojson.Safe.t -> (Wire.bridge_message, string) Result.t
