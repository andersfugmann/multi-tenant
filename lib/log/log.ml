open! Base
open! Stdio

let log fmt =
  Printf.ksprintf
    (fun msg -> printf "[Alloy] %s\n%!" msg)
    fmt
