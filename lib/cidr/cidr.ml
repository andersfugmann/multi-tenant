open! Base
open! Stdio

type t = { addr : bytes; prefix_len : int }

let parse_ipv4 s =
  let parts = String.split s ~on:'.' in
  match List.map parts ~f:Int.of_string_opt |> Option.all with
  | Some [ a; b; c; d ]
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
  List.map strs ~f:(fun p -> Int.of_string_opt ("0x" ^ p))
  |> Option.all

let expand_ipv6_groups s =
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

let ip_to_bytes s =
  match parse_ipv4 s with
  | Some b -> Some b
  | None -> parse_ipv6 s

let parse s =
  let make addr prefix_len =
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
    | (Some addr, Some prefix_len) -> make addr prefix_len
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

let ip_matches ip cidr =
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
  List.exists allowed_networks ~f:(fun cidr -> ip_matches ip cidr)
