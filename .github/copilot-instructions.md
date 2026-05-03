# OCaml Coding Guidelines

## Language and Style

- Always `open! Base` and `open! Stdio` at the top of every module.
- Prefer higher-order functions (`List.map`, `List.filter`, `List.fold`, `Option.bind`, etc.) over manual recursion.
- Never use `for` or `while` loops.
- Never use `if` expressions; use pattern matching instead.
- Prefer the `|>` (pipe) operator to chain transformations.
- Avoid redundant checks (e.g., do not test if a list is empty before calling `List.iter` or `List.map`).
- Functions should be pure. Limit call depth; recursion is acceptable when needed.
- Only add type signatures to functions when strictly needed (e.g., to resolve ambiguity, for GADTs, or in `.mli` files).
- Avoid mutable data structures (`ref`, mutable record fields, `Hashtbl`). Use `Map`, `Set`, and immutable records.
- Avoid nested `match` expressions where possible; factor inner matches into helper functions.
- Prefer `begin match ... end` over `(match ...)` when a match expression must appear inside another expression.

## Libraries and Dependencies

- Always use `Base` and `Stdio` as the standard library.
- Prefer ppx derivers (`ppx_deriving`, `ppx_deriving_yojson`, `ppx_sexp_conv`, `ppx_compare`, etc.) over hand-written boilerplate.
- Prefer existing opam packages over manual reimplementation.

## Module Design

- Each module should have a clear, single area of responsibility with clean separation of concerns.
- Only create `.mli` files when implementation details must be hidden (e.g., opaque types, internal helper functions). If the full public interface matches the implementation, omit the `.mli`.

## js_of_ocaml

- Never use `Js.Unsafe`. All JavaScript interop must go through typed bindings.

## Build System

- Use `dune` as the build system.
