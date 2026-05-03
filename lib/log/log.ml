open! Stdio

let printf fmt =
  Printf.ksprintf
    (fun msg -> printf "[Alloy] %s\n%!" msg)
    fmt
