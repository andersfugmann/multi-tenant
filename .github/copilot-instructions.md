# Copilot Instructions

## Project Overview

This is the **url-router** project — a multi-tenant URL routing system for Linux desktops. It routes URLs to the correct browser across host and systemd-nspawn container tenants. The project is a Cargo workspace with three Rust crates (`url-router`, `url-router-native-host`, and `url-router-protocol`) and a Chromium browser extension (TypeScript).

## Code Quality Principles

### Readability First

- Write code that reads like prose. Prefer clarity over cleverness.
- Use descriptive names that convey intent: `find_matching_rule` not `match_r`, `tenant_id` not `tid`.
- Keep functions short — a function should do one thing and its name should describe that thing.
- Avoid abbreviations unless universally understood (`url`, `config`, `id` are fine; `cfg`, `ctx`, `mgr` are not).

### Simplicity

- Prefer the simplest solution that works correctly.
- Avoid premature abstraction — extract a pattern only when it appears at least twice.
- Avoid deep nesting. Use early returns, `if let`, and `?` to keep the happy path at the top level.

### Derive Macros and Code Generation

- **Use derive macros and code generation wherever possible.** Never hand-write what a macro can generate correctly.
- In Rust: use `serde::Deserialize` / `serde::Serialize` for all JSON serialization — never hand-parse JSON or config files. Use `clap::Parser` for CLI args. Use `thiserror::Error` for error types. Use `derive_more` for `Display`, `From`, `FromStr` and other trait impls.
- For the line-based socket protocol: use `FromStr` and `Display` impls (derived via `derive_more` where possible) for command/response parsing. The protocol is text-based, not JSON, so serde does not apply to the line framing — but it does apply to embedded JSON payloads (e.g., the JSON in `add-rule <json>` and `CONFIG <json>`).
- In TypeScript: use `zod` schemas to define and validate all external data structures — never hand-write type guards or manual field-by-field validation. Infer TypeScript types from zod schemas with `z.infer<>`.
- If a macro or derive can replace boilerplate, use it. The goal is to declare intent and let the tooling generate the implementation.

### Purity and Side Effects

- **Keep functions pure whenever possible.** A function that takes inputs and returns outputs with no side effects is easy to test, understand, and reuse.
- Isolate side effects (file I/O, socket I/O, process spawning, notifications) at the boundaries. Core logic modules must not perform I/O directly.
- Pass data into functions, don't have functions reach out to global state or singletons.
- If a function must perform side effects, make that explicit in its name and signature (e.g., `write_config_to_file`, not `update_config`).

### Separation of Concerns

Structure the code into modules with clear, non-overlapping responsibilities. Each module should have a single reason to change.

**Rust (`url-router-protocol`, shared crate):**
- `config` — Config types (`Config`, `Tenant`, `Rule`, `Defaults`) with serde derives. Pure parsing: `Config::from_json(content: &str) -> Result<Config>`. No file I/O.
- `matching` — URL-to-tenant rule evaluation. Pure functions only. Takes a URL and rules, returns a match result.
- `protocol` — Protocol command and response types as enums, with `FromStr`/`Display` impls for line format conversion. Serde derives for the embedded JSON payloads. No I/O.
- `types` — Shared newtypes: `TenantId`, `RuleIndex`, etc.

**Rust (`url-router`, daemon + CLI):**
- `daemon` — Socket listener, connection handling, command dispatch. This is where I/O lives. Uses `std::thread` for concurrency.
- `forwarding` — Cross-tenant communication (connecting to peer sockets, sending commands).
- `browser` — Browser process launching. Thin wrapper around `Command`.
- `notification` — Desktop notification sending.
- `cli` — CLI argument parsing and subcommand dispatch (clap).
- `config_io` — Config file reading, writing, and inotify watching. Uses `url-router-protocol::config` for parsing.

**Rust (`url-router-native-host`):**
- `framing` — Chrome native messaging length-prefixed framing (read/write).
- `translate` — Convert between JSON messages and protocol line format. Pure functions. Uses types from `url-router-protocol`.
- `bridge` — Connect stdin/stdout to daemon socket. I/O boundary.

**Browser extension:**
- `background.ts` — Service worker: navigation interception, native messaging port lifecycle.
- `daemon-client.ts` — Typed wrapper for daemon communication (open, open-on, add-rule, get-config, test).
- `protocol.ts` — Zod schemas and inferred types for all daemon messages (Command, DaemonResponse, Config, Tenant). Single source of truth for types and validation.
- `popup.ts` — Popup UI logic. Communicates with background via `chrome.runtime.sendMessage`.
- `menu.ts` — Context menu setup and handling.
- `badge.ts` — Toolbar badge management.

### Code Reuse

- Extract shared logic into generic, reusable functions. Prefer small composable functions over large monolithic ones.
- Use Rust's type system and traits to enable reuse without duplication.
- When two pieces of code do similar things, extract the common pattern into a function parameterized by the differences.
- The `url-router-protocol` crate is shared by both `url-router` and `url-router-native-host` — all protocol and config types live there. No duplication.

### Avoid Long Call Chains

- Assign intermediate results to named variables when it clarifies what each step produces.
- Iterator pipelines (`iter().filter().find()`) are fine when they read as a natural data pipeline. Break them up when the logic branches, when closures are complex, or when intermediate values deserve a name.
- Avoid deeply nested closures. Extract them into named functions.
- In async code, keep `.await` chains short — name intermediate futures.

```rust
// Fine: natural iterator pipeline, reads clearly
let matched_rule = config.active_rules().find(|r| r.pattern.is_match(url));

// Better when logic is more involved: name the steps
let active_rules = config.rules.iter().filter(|r| r.is_enabled());
let matched_rule = active_rules.find(|r| r.pattern.is_match(url));
let tenant = match matched_rule {
    Some(rule) => &rule.tenant,
    None => &config.defaults.unmatched,
};
```

### Error Handling

- Use `Result` and `?` for recoverable errors. Use typed error enums, not string errors.
- Use `thiserror` for defining error types.
- Don't panic in library code. Reserve `unwrap`/`expect` for cases that are provably infallible (and add a comment explaining why).
- Log errors with context at the point where they're handled, not where they originate.

### Logging

- Use the `tracing` crate for all logging. Never use `println!` or `eprintln!` for diagnostic output.
- Log levels:
  - `error` — Failures that prevent a request from being handled (socket errors, browser launch failures).
  - `warn` — Degraded behavior (peer daemon unreachable, fallback to local).
  - `info` — Routing decisions (`url=... tenant=... rule_index=...`). One line per `open`/`open-on` command.
  - `debug` — Connection lifecycle, config reloads, command dispatch details.
  - `trace` — Raw protocol lines, byte-level I/O.
- Use structured fields, not interpolated strings: `tracing::info!(url = %url, tenant = %tenant, "routing decision")`.

### Concurrency Model

- The daemon uses **`std::thread`** for concurrency — no async runtime. The workload (2-3 concurrent connections, microsecond request handling) does not justify an async runtime.
- Main thread runs the accept loop on `UnixListener`. Each connection is handled in a spawned thread with blocking I/O.
- A dedicated thread watches the config file via inotify and updates shared state.
- Shared config is protected by `Arc<RwLock<Config>>` — simple and sufficient for this workload.
- Use `std::os::unix::net` for Unix domain sockets, not tokio.
- Use `std::fs` for file operations, not async equivalents.

### Testing

- Write unit tests for all pure functions (matching, protocol parsing, config validation).
- Use integration tests for I/O boundaries (daemon socket, native messaging framing).
- Test the protocol module with round-trip tests: parse a command string, serialize it back, verify equality.
- Keep test data in the test itself (not external files) unless the data is large.
- Name tests descriptively: `test_route_returns_local_when_url_matches_own_tenant`.

### Documentation

- Add a doc comment (`///`) to every public function, struct, and module explaining **what** it does (not how).
- Module-level doc comments (`//!`) should describe the module's responsibility and what it does NOT do.
- Don't document obvious things. `/// Returns the tenant ID` on `fn tenant_id(&self) -> &str` adds no value.

### Type-Driven Design (Rust and TypeScript)

- **Encode invariants in the type system.** If something can't be invalid, make it impossible to construct an invalid value.
- **Use algebraic data types (ADTs)** to model domain concepts precisely. Use Rust `enum` and TypeScript discriminated unions to represent states, commands, and responses.
- **Parse, don't validate.** All external data (config files, socket messages, Chrome API payloads, native messaging JSON) must be parsed into strongly-typed internal structures at the boundary. Once parsed, the rest of the code works with types that are guaranteed valid — no re-checking, no stringly-typed data flowing through the system.
- **Make illegal states unrepresentable.** Resolve optionality at parse time — e.g., config's `enabled` field (`Option<bool>`) should be resolved to a concrete `bool` (default `true`) during parsing, so downstream code never handles `None`.
- **Use newtypes** to distinguish domain concepts that share underlying types: `struct TenantId(String)`, `struct RuleIndex(usize)`.

```rust
// Parse at boundary, process typed data
enum Command {
    Open { url: Url },
    OpenOn { tenant: TenantId, url: Url },
    Test { url: Url },
    AddRule { rule: RuleDefinition },
    GetConfig,
    Status,
}

enum Response {
    Local,
    Remote { tenant: TenantId },
    Fallback,
    // ...
}

fn handle_command(cmd: Command, config: &Config) -> Response { ... }
```

### Rust-Specific Guidelines

- **JSON serialization via serde.** Config parsing and JSON payloads within the protocol must use `#[derive(Serialize, Deserialize)]`.
- **Line protocol via `FromStr`/`Display`.** The socket protocol's text framing uses `FromStr` and `Display` impls, derived via `derive_more` where possible.
- Prefer borrowing (`&str`, `&Config`) over cloning. Clone only when ownership transfer is genuinely needed.
- Use `impl Into<String>` or generics for function parameters that accept both owned and borrowed strings, only when the function needs to own the string.
- Derive `Debug`, `Clone`, `PartialEq` on all data types by default. Add `Serialize`, `Deserialize` on types that cross serialization boundaries.
- Use `#[cfg(test)]` modules at the bottom of each file for unit tests.
- Use `clap::Parser` derive for CLI argument parsing.
- Use `thiserror::Error` derive for error types — never `impl Display` for errors by hand.

### TypeScript-Specific Guidelines (Browser Extension)

- The browser extension is written in **TypeScript** with strict mode (`"strict": true` in tsconfig).
- **All functions must have explicit parameter and return types.** No implicit `any`.
- Use **discriminated unions** (tagged unions) for message types, daemon responses, and UI states.
- **Parse all external data at the boundary using `zod` schemas.** Define zod schemas for every external data shape (native messaging responses, Chrome API results, config). Infer TypeScript types from schemas with `z.infer<typeof schema>`. Never write manual type guards or field-by-field validation.
- Use `const` by default, `let` only when mutation is needed. Never use `var`.
- Use `readonly` on properties and arrays that should not be mutated.
- Keep the service worker (`background.ts`) minimal — it should delegate to helper modules.
- All communication with the native messaging host should go through a single typed abstraction (e.g., a `DaemonClient` class) rather than calling `chrome.runtime.sendNativeMessage` directly.
- Handle Chrome API errors explicitly — check `chrome.runtime.lastError` where applicable.
- Use `async`/`await` over raw promises. No callbacks.

```typescript
// Define schema — single source of truth for type and validation
const DaemonResponseSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("LOCAL") }),
  z.object({ status: z.literal("REMOTE"), tenant: z.string() }),
  z.object({ status: z.literal("FALLBACK") }),
  z.object({ status: z.literal("OK"), detail: z.string() }),
  z.object({ status: z.literal("CONFIG"), data: ConfigSchema }),
  z.object({ status: z.literal("ERR"), message: z.string() }),
]);

// Type inferred from schema — no duplication
type DaemonResponse = z.infer<typeof DaemonResponseSchema>;

// Parse at boundary — one line, fully validated
function parseDaemonResponse(raw: unknown): DaemonResponse {
  return DaemonResponseSchema.parse(raw);
}
```

**Extension file structure:**
- `background.ts` — Service worker: navigation interception, native messaging port lifecycle.
- `daemon-client.ts` — Typed wrapper for daemon communication (route, open-on, add-rule, get-config, test).
- `protocol.ts` — Zod schemas and inferred types for all daemon messages. Single source of truth.
- `popup.ts` — Popup UI logic.
- `menu.ts` — Context menu setup and handling.
- `badge.ts` — Toolbar badge management.

### Commit Practices

- Each commit should be a single logical change that compiles and passes tests.
- Write commit messages in imperative mood: "Add URL matching module", not "Added URL matching".
- Reference the relevant todo/task in the commit body when applicable.
