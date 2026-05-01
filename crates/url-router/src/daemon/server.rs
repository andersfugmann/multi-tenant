//! Unix socket server — accept loop, connection threads, and I/O dispatch.
//!
//! This is the main I/O boundary for the daemon. It listens on a Unix socket,
//! spawns a thread per connection, parses protocol commands, dispatches to the
//! handler, and executes any resulting actions (browser launch, forwarding).

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::{Duration, Instant};

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
    /// URLs recently opened via `open-local` (from peer forwarding).
    /// Checked on `open` to prevent routing loops.
    pub cooldown: Mutex<HashMap<String, Instant>>,
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

    // Special handling for rule mutations (need config file write)
    if let Command::AddRule { ref rule } = cmd {
        return handle_rule_validation_and_write(
            rule,
            state,
            |rule| config_io::add_rule(&state.config_path, rule.clone().into()),
            "rule added",
        );
    }

    if let Command::UpdateRule { index, ref rule } = cmd {
        return handle_rule_validation_and_write(
            rule,
            state,
            |rule| config_io::update_rule(&state.config_path, index.0, rule.clone().into()),
            "rule updated",
        );
    }

    if let Command::DeleteRule { index } = cmd {
        match config_io::delete_rule(&state.config_path, index.0) {
            Ok(_) => {
                info!(index = index.0, "rule deleted");
                return Response::Ok;
            }
            Err(e) => {
                error!(error = %e, "failed to delete rule");
                return Response::Error {
                    message: e.to_string(),
                };
            }
        }
    }

    if let Command::SetConfig { ref json } = cmd {
        let new_config = match url_router_protocol::config::Config::from_json(json) {
            Ok(c) => c,
            Err(e) => {
                return Response::Error {
                    message: format!("invalid config JSON: {e}"),
                };
            }
        };

        // Validate all rules reference existing tenants and have valid regexes
        if let Some(err) = new_config.rules.iter().find_map(|rule| {
            if new_config.tenant(rule.tenant.as_str()).is_none() {
                return Some(Response::ErrorUnknownTenant {
                    tenant: rule.tenant.clone(),
                });
            }
            regex::Regex::new(&rule.pattern).err().map(|e| Response::Error {
                message: format!("invalid regex in rule: {e}"),
            })
        }) {
            return err;
        }

        return match config_io::set_config(&state.config_path, new_config) {
            Ok(_) => {
                info!("config replaced via set-config");
                Response::Ok
            }
            Err(e) => {
                error!(error = %e, "failed to write config");
                Response::Error {
                    message: e.to_string(),
                }
            }
        };
    }

    // Cooldown check: if this URL was recently opened via open-local,
    // force LOCAL to prevent routing loops.
    if let Command::Open { ref url } = cmd {
        if is_cooling_down(state, url) {
            debug!(url = %url, "cooldown active, forcing LOCAL");
            return Response::Local;
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
            // Record cooldown when the open was triggered by a peer (open-local)
            record_cooldown(state, &url);
            info!(url = %url, browser = browser_cmd, "opened locally");
            response
        }
        Action::ForwardToPeer {
            tenant,
            url,
            on_success,
            on_failure,
        } => {
            let socket = config.tenant(tenant.as_str()).map(|t| t.socket.as_str());

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

/// Check if a URL is in the cooldown window.
fn is_cooling_down(state: &DaemonState, url: &str) -> bool {
    let cooldown_secs = state
        .config
        .read()
        .map(|c| c.defaults.cooldown_secs)
        .unwrap_or(5);
    let cooldown = Duration::from_secs(cooldown_secs);

    let mut map = state.cooldown.lock().unwrap();
    if let Some(opened_at) = map.get(url) {
        if opened_at.elapsed() < cooldown {
            return true;
        }
        // Expired — clean up
        map.remove(url);
    }
    false
}

/// Record a URL in the cooldown map (called after open-local launches browser).
fn record_cooldown(state: &DaemonState, url: &str) {
    let mut map = state.cooldown.lock().unwrap();
    map.insert(url.to_string(), Instant::now());

    // Periodic cleanup: remove entries older than 60s to prevent unbounded growth
    let cutoff = Duration::from_secs(60);
    map.retain(|_, t| t.elapsed() < cutoff);
}

/// Validate a rule (tenant exists, regex compiles) then execute a config write.
fn handle_rule_validation_and_write(
    rule: &url_router_protocol::config::RuleDefinition,
    state: &DaemonState,
    write_fn: impl FnOnce(
        &url_router_protocol::config::RuleDefinition,
    ) -> Result<(), config_io::ConfigIoError>,
    success_msg: &str,
) -> Response {
    let config = state.config.read().unwrap();
    if config.tenant(rule.tenant.as_str()).is_none() {
        return Response::ErrorUnknownTenant {
            tenant: rule.tenant.clone(),
        };
    }
    if let Err(e) = regex::Regex::new(&rule.pattern) {
        return Response::Error {
            message: format!("invalid regex: {e}"),
        };
    }
    drop(config);

    match write_fn(rule) {
        Ok(_) => {
            info!(pattern = %rule.pattern, tenant = %rule.tenant, "{}", success_msg);
            Response::Ok
        }
        Err(e) => {
            error!(error = %e, "failed to write config");
            Response::Error {
                message: e.to_string(),
            }
        }
    }
}

/// Build a STATUS response with runtime daemon information.
fn build_status(state: &DaemonState) -> Response {
    let config = state.config.read().unwrap();
    let uptime = state.start_time.elapsed().as_secs();

    let peers = config
        .tenants
        .iter()
        .filter(|(id, _)| id.as_str() != state.tenant.as_str())
        .map(|(id, tenant)| {
            let status = if Path::new(&tenant.socket).exists() {
                "reachable"
            } else {
                "unreachable"
            };
            (id.clone(), status.to_string())
        })
        .collect();

    let status_info = StatusInfo {
        tenant: state.tenant.clone(),
        uptime_secs: uptime,
        config_path: state.config_path.clone(),
        rule_count: config.rules.len(),
        peers,
    };

    let json =
        serde_json::to_string(&status_info).unwrap_or_else(|e| format!("{{\"error\": \"{e}\"}}"));
    Response::Status { json }
}
