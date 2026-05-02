# URL Router — System Specification

## Overview

URL Router is a multi-tenant URL routing system for Linux desktops using systemd-nspawn containers. A single daemon on the host routes URLs between isolated browser instances, each running in a different tenant (host machine or container). Tenants are identified by their hostname.

## Components

There are three components:

- **url-router** — the daemon, runs on the host only
- **url-router-client** — the native messaging bridge and CLI tool, runs in every tenant
- **Browser extension** — a Chromium extension, installed in every tenant's browser

## Daemon

The daemon listens on a single Unix socket shared between all tenants (bind-mounted into containers). It accepts two kinds of connections:

### Registered connections

A client sends `register <tenant_id>` as its first message. On success, the connection becomes long-lived and read-only from the client's perspective. The daemon pushes URL open requests to the client by writing `NAVIGATE <url>` lines on this connection. When the connection drops, the tenant is unregistered.

Only one registered connection per tenant is allowed. Duplicate registrations are rejected.

### Command connections

All other connections are one-shot: the client sends a single command, reads a single response, and closes the connection.

### State

The daemon holds the following state:

- **Tenant registry** — which tenants have active registered connections
- **Cooldown map** — recently routed (tenant, URL) pairs, used to suppress redirect loops
- **Configuration** — loaded from a JSON file and reloaded automatically on file changes

### Routing logic

When the daemon receives an `open` command:

1. If the source tenant is `default` (CLI/desktop entry), evaluate rules and always push the URL to the resolved target tenant. Never respond LOCAL.
2. If the source tenant is a real tenant (browser extension), check cooldown first. If cooling down, respond LOCAL. Otherwise evaluate rules. If the target is the source tenant or `local`, respond LOCAL. Otherwise push the URL to the target tenant and respond REMOTE.

Pushing a URL means writing `NAVIGATE <url>` on the target tenant's registered connection. If the target tenant is not registered, the daemon can launch the tenant's browser via its configured `browser_cmd` and wait for registration.

### Rule evaluation

Rules are regex patterns matched against the full URL, evaluated top-to-bottom. The first enabled rule whose pattern matches determines the target tenant. If no rule matches, the configured `defaults.unmatched` value is used (`local` keeps the URL in the current tenant, or a tenant hostname to route there).

## Protocol

The protocol is line-based (one message per line, newline-terminated) over a Unix socket.

### Commands (client → daemon)

All commands may return `ERR <message>` on failure.

| Command | Description | Responses |
|---|---|---|
| `REGISTER <tenant_id>` | Register as a listener for this tenant | OK, ERR |
| `OPEN <tenant_id> <url>` | Route a URL (tenant_id = source tenant) | LOCAL, REMOTE, ERR |
| `OPEN-ON <tenant_id> <target> <url>` | Send URL to a specific target tenant | REMOTE, ERR |
| `TEST <tenant_id> <url>` | Dry-run rule evaluation | MATCH, NOMATCH, ERR |
| `GET-CONFIG <tenant_id>` | Retrieve configuration | CONFIG, ERR |
| `SET-CONFIG <tenant_id> <json>` | Replace entire configuration | OK, ERR |
| `ADD-RULE <tenant_id> <json>` | Append a routing rule | OK, ERR |
| `UPDATE-RULE <tenant_id> <index> <json>` | Replace a rule at an index | OK, ERR |
| `DELETE-RULE <tenant_id> <index>` | Remove a rule by index | OK, ERR |
| `STATUS <tenant_id>` | Daemon status (registered tenants, counts) | STATUS, ERR |

### Responses (daemon → client on command connections)

| Response | Meaning |
|---|---|
| `OK` | Success |
| `LOCAL` | URL belongs to the requesting tenant; keep it |
| `REMOTE <tenant_id>` | URL pushed to the named tenant |
| `MATCH <tenant_id> <rule_index>` | Test result: URL matches a rule |
| `NOMATCH <default_tenant>` | Test result: no rule matched |
| `CONFIG <json>` | Full configuration as JSON |
| `STATUS <json>` | Daemon status as JSON |
| `ERR <message>` | Error with description |

### Server push (daemon → client on registered connections)

| Message | Meaning |
|---|---|
| `NAVIGATE <url>` | Open this URL in the tenant's browser |

### Parsing rules

- The URL is always the last field and extends to the end of the line (it may contain spaces).
- Tenant IDs are alphanumeric, hyphens, and dots. The synthetic ID `default` is reserved for CLI usage and cannot appear in configuration.
- JSON payloads in commands are inline to end of line.

## Native Messaging Bridge (url-router-client)

The url-router-client binary operates in two modes:

### Native messaging mode

Activated when the browser spawns it (no CLI arguments or a `chrome-extension://` argument). It:

1. Reads the system hostname to determine its tenant ID.
2. Opens a registered connection to the daemon and sends `register <hostname>`. A background thread reads `NAVIGATE` pushes from this connection and forwards them to the browser extension as JSON messages on stdout.
3. Reads JSON commands from the browser extension on stdin. For each command, it opens a new one-shot connection to the daemon, translates the JSON to a protocol line (injecting the tenant ID), reads the response, translates it back to JSON, and writes it to stdout.

The extension never sends or knows its own tenant ID — the native messaging host adds it transparently.

If the daemon connection drops, the push fiber exits and the bridge notifies the extension of the disconnect.

### CLI mode

Activated when invoked with arguments. Connects to the daemon, sends the command using `default` as the tenant ID, prints the response, and exits.

Available CLI commands: `open <url>`, `open-on <tenant> <url>`, `test <url>`, `get-config`, `set-config <json-file>`, `add-rule <json>`, `update-rule <index> <json>`, `delete-rule <index>`, `status`.

## Browser Extension

### Navigation interception

The extension intercepts all HTTP/HTTPS navigations in the top frame via `webNavigation.onBeforeNavigate`. For each navigation, it sends an `open` command (without tenant ID — the native host adds it) to the daemon and waits for the response:

- **LOCAL** — do nothing, let the navigation proceed
- **REMOTE** — the URL has been pushed to another tenant's browser; close the tab (or go back if the tab had prior history)
- **ERR** — log the error, keep the tab

### Receiving URLs (NAVIGATE push)

When the daemon pushes a `NAVIGATE` message (via the registered connection), the extension opens a new tab with the given URL. This is how URLs arrive from other tenants.

### Cooldown / loop prevention

The daemon tracks recently routed (tenant, URL) pairs. If the same URL is routed again within the cooldown window, the daemon responds LOCAL to prevent redirect loops. This handles the case where a NAVIGATE push triggers another `open` in the receiving tenant's extension.

### Toolbar badge

After each completed navigation, the extension sends a `test` command for the current URL. If the URL matches a rule, the toolbar badge shows the target tenant's configured label and color, giving a visual indicator of which tenant "owns" the page.

### Context menus

Right-clicking on a page shows:

- **Send to > \<tenant\>** — sends the current page's URL to the chosen tenant via `open-on` and closes the tab
- **Assign tenant…** — opens a dialog to create a permanent routing rule

Right-clicking on a link shows:

- **Open link in > \<tenant\>** — sends the link's URL to the chosen tenant via `open-on`

### Assign tenant dialog

Opened from the context menu. Presents:

- The current URL
- A pre-filled regex pattern (defaults to the URL's origin)
- A tenant dropdown populated from the configuration
- A checkbox to also open the URL in the chosen tenant immediately

Saving sends an `add-rule` command to the daemon, persisting the rule.

### Popup

Clicking the extension icon shows:

- The current tab's URL
- An "Open in \<tenant\>" button for each configured tenant (sends `open-on`)
- A "Remember" button that lets the user pick a tenant and creates a routing rule for the current URL's origin

### Settings page

A full configuration editor accessible from the popup. Three tabs:

- **Rules** — table of all routing rules with editable pattern, tenant dropdown, enabled checkbox. Rules can be added and deleted.
- **Tenants** — cards for each tenant showing browser command, badge label, and badge color. Tenants can be added and deleted (deletion is blocked if rules reference the tenant).
- **Defaults** — socket path, unmatched behavior, notification settings, cooldown duration, browser launch timeout.

All changes are saved by sending a `set-config` command to the daemon with the full updated configuration.

## Configuration

The daemon reads its configuration from a JSON file. The configuration contains:

- **socket** — path to the Unix socket
- **tenants** — a map from hostname to tenant settings (browser command, badge label, badge color)
- **rules** — an ordered list of routing rules (regex pattern, target tenant, enabled flag)
- **defaults** — unmatched behavior, notification settings, cooldown duration, browser launch timeout

The daemon watches the file for changes and reloads automatically. The extension can also replace the configuration via `set-config`.

Tenant map keys must match the machine's actual hostname. The `browser_cmd` must be the actual browser binary (not `xdg-open`, which would loop when url-router is the default URL handler). For containers, the command includes `machinectl shell`.
