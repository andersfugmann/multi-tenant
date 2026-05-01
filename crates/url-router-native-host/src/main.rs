//! Chrome native messaging host bridge for url-router.
//!
//! Translates between Chrome's length-prefixed JSON protocol (stdin/stdout)
//! and the daemon's line-based Unix socket protocol.
//!
//! Chrome spawns this binary as a subprocess. It maintains a persistent
//! connection to the daemon socket for the lifetime of the messaging port.

mod bridge;
mod framing;
mod translate;

use std::io;
use std::os::unix::net::UnixStream;

fn main() {
    let socket_path = find_socket_path();

    let mut daemon = match UnixStream::connect(&socket_path) {
        Ok(stream) => stream,
        Err(e) => {
            let err = translate::error_response(&format!("cannot connect to daemon: {e}"));
            let _ = framing::write_message(&mut io::stdout().lock(), &err);
            std::process::exit(1);
        }
    };

    let stdin = io::stdin();
    let mut stdin = stdin.lock();
    let stdout = io::stdout();
    let mut stdout = stdout.lock();

    while let Ok(json_bytes) = framing::read_message(&mut stdin) {
        // Translate JSON to line command
        let line_cmd = match translate::json_to_line(&json_bytes) {
            Ok(cmd) => cmd,
            Err(e) => {
                let err = translate::error_response(&e);
                let _ = framing::write_message(&mut stdout, &err);
                continue;
            }
        };

        // Send to daemon
        if let Err(e) = bridge::send_line(&mut daemon, &line_cmd) {
            let err = translate::error_response(&format!("daemon send failed: {e}"));
            let _ = framing::write_message(&mut stdout, &err);
            continue;
        }

        // Read daemon response
        let response_line = match bridge::read_line(&mut daemon) {
            Ok(line) => line,
            Err(e) => {
                let err = translate::error_response(&format!("daemon read failed: {e}"));
                let _ = framing::write_message(&mut stdout, &err);
                continue;
            }
        };

        // Translate line response to JSON
        let json_response = translate::line_to_json(&response_line);

        // Write length-prefixed JSON to Chrome
        if framing::write_message(&mut stdout, &json_response).is_err() {
            break; // stdout closed — Chrome closed the port
        }
    }
}

/// Find the daemon socket path.
///
/// Priority: URL_ROUTER_SOCKET env var > scan config file > hardcoded default.
fn find_socket_path() -> String {
    if let Ok(path) = std::env::var("URL_ROUTER_SOCKET") {
        return path;
    }

    // Try to read config and find a reachable socket
    let config_path = url_router_protocol::config::default_config_path();

    if let Ok(content) = std::fs::read_to_string(&config_path) {
        if let Ok(config) = url_router_protocol::config::Config::from_json(&content) {
            for tenant in config.tenants.values() {
                if std::path::Path::new(&tenant.socket).exists() {
                    return tenant.socket.clone();
                }
            }
        }
    }

    "/run/url-router/host.sock".to_string()
}
