//! Unix socket server — accept loop, connection threads, and I/O dispatch.
//!
//! This is the main I/O boundary for the daemon. It listens on a Unix socket,
//! spawns a thread per connection, parses protocol commands, dispatches to the
//! handler, and executes any resulting actions (browser launch, forwarding).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Instant;

use tracing::{debug, error, info, warn};
use url_router_protocol::config::Config;
use url_router_protocol::protocol::{Command, Response, StatusInfo};
use url_router_protocol::types::TenantId;

use super::handler::{handle_command, Action};
use crate::browser;
use crate::config_io;
use crate::forwarding;
use crate::notification;

/// Shared daemon state, accessible from all connection threads.
pub struct DaemonState {
    pub config: Arc<RwLock<Config>>,
    pub tenant: TenantId,
    pub config_path: String,
    pub start_time: Instant,
}

/// Start the daemon server on the given socket path.
///
/// Blocks forever (or until an error occurs) accepting connections.
/// Each connection is handled in a separate thread.
pub fn run(socket_path: &Path, state: Arc<DaemonState>) -> std::io::Result<()> {
    // Clean up stale socket file
    if socket_path.exists() {
        std::fs::remove_file(socket_path)?;
    }

    let listener = UnixListener::bind(socket_path)?;
    info!(path = %socket_path.display(), "daemon listening");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let state = Arc::clone(&state);
                thread::spawn(move || {
                    if let Err(e) = handle_connection(stream, &state) {
                        debug!(error = %e, "connection ended");
                    }
                });
            }
            Err(e) => {
                error!(error = %e, "failed to accept connection");
            }
        }
    }

    Ok(())
}

/// Handle a single client connection (blocking, runs in a spawned thread).
fn handle_connection(stream: UnixStream, state: &DaemonState) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut writer = stream;
    let mut line = String::new();

    loop {
        line.clear();
        let bytes_read = reader.read_line(&mut line)?;
        if bytes_read == 0 {
            return Ok(()); // EOF — client disconnected
        }

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let response = process_line(trimmed, state);
        writeln!(writer, "{response}")?;
        writer.flush()?;
    }
}

/// Parse a protocol line, dispatch to handler, execute actions, return response.
fn process_line(line: &str, state: &DaemonState) -> Response {
    let cmd = match line.parse::<Command>() {
        Ok(cmd) => cmd,
        Err(e) => {
            warn!(line = line, error = %e, "invalid command");
            return Response::Error {
                message: e.to_string(),
            };
        }
    };

    // Special handling for status (needs runtime data)
    if matches!(cmd, Command::Status) {
        return build_status(state);
    }

    // Special handling for add-rule (needs config file write)
    if let Command::AddRule { ref rule } = cmd {
        let config = state.config.read().unwrap();
        // Validate tenant exists
        if config.tenant(rule.tenant.as_str()).is_none() {
            return Response::ErrorUnknownTenant {
                tenant: rule.tenant.clone(),
            };
        }
        // Validate regex
        if let Err(e) = regex::Regex::new(&rule.pattern) {
            return Response::Error {
                message: format!("invalid regex: {e}"),
            };
        }
        drop(config);

        // Write to config file
        match config_io::add_rule(&state.config_path, rule.clone().into()) {
            Ok(_) => {
                info!(pattern = %rule.pattern, tenant = %rule.tenant, "rule added");
                return Response::Ok;
            }
            Err(e) => {
                error!(error = %e, "failed to add rule");
                return Response::Error {
                    message: format!("failed to write config: {e}"),
                };
            }
        }
    }

    let config = state.config.read().unwrap();
    let action = handle_command(cmd, &config, &state.tenant);

    match action {
        Action::Respond(response) => response,
        Action::OpenLocalBrowser { url, response } => {
            let browser_cmd = config
                .tenant(state.tenant.as_str())
                .map(|t| t.browser_cmd.as_str())
                .unwrap_or("xdg-open");
            if let Err(e) = browser::launch(browser_cmd, &url) {
                error!(error = %e, url = %url, "browser launch failed");
                return Response::Error {
                    message: format!("browser launch failed: {e}"),
                };
            }
            info!(url = %url, browser = browser_cmd, "opened locally");
            response
        }
        Action::ForwardToPeer {
            tenant,
            url,
            on_success,
            on_failure,
        } => {
            let socket = config
                .tenant(tenant.as_str())
                .map(|t| t.socket.as_str());

            match socket {
                Some(socket_path) => {
                    match forwarding::forward_open_local(socket_path, &url) {
                        Ok(_) => {
                            info!(url = %url, tenant = %tenant, "forwarded to peer");
                            on_success
                        }
                        Err(e) => {
                            warn!(url = %url, tenant = %tenant, error = %e, "peer unreachable, falling back");
                            // Notify the user about the fallback
                            if config.defaults.notifications {
                                let _ = notification::show_routing_notification(
                                    "URL Router: Fallback",
                                    &format!("Tenant '{}' unreachable. Opening locally.", tenant),
                                    config.defaults.notification_timeout_ms,
                                );
                            }
                            // Fallback: try to open locally
                            let browser_cmd = config
                                .tenant(state.tenant.as_str())
                                .map(|t| t.browser_cmd.as_str())
                                .unwrap_or("xdg-open");
                            let _ = browser::launch(browser_cmd, &url);
                            on_failure
                        }
                    }
                }
                None => {
                    warn!(tenant = %tenant, "no socket configured for tenant");
                    on_failure
                }
            }
        }
    }
}

/// Build a STATUS response with runtime daemon information.
fn build_status(state: &DaemonState) -> Response {
    let config = state.config.read().unwrap();
    let uptime = state.start_time.elapsed().as_secs();

    let mut peers = std::collections::HashMap::new();
    for (id, tenant) in &config.tenants {
        if id != state.tenant.as_str() {
            let status = if Path::new(&tenant.socket).exists() {
                "reachable"
            } else {
                "unreachable"
            };
            peers.insert(id.clone(), status.to_string());
        }
    }

    let status_info = StatusInfo {
        tenant: state.tenant.clone(),
        uptime_secs: uptime,
        config_path: state.config_path.clone(),
        rule_count: config.rules.len(),
        peers,
    };

    let json = serde_json::to_string(&status_info)
        .unwrap_or_else(|e| format!("{{\"error\": \"{e}\"}}"));
    Response::Status { json }
}
