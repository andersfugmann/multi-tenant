//! Native messaging bridge mode.
//!
//! Connects the Chrome extension (via stdin/stdout native messaging) to the
//! daemon (via Unix socket). Maintains a long-lived registered listener
//! connection for NAVIGATE pushes, and opens short-lived connections for
//! individual commands.

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use serde_json::Value;
use url_router_protocol::types::TenantId;

use crate::framing;
use crate::translate;

/// Run the native messaging bridge.
///
/// This is the main entry point when the binary is invoked by Chrome.
/// It registers with the daemon, starts a listener for NAVIGATE pushes,
/// and processes commands from stdin.
pub fn run(socket_path: &str, tenant_id: TenantId) {
    let (write_tx, write_rx) = mpsc::channel::<Value>();

    // Start the stdout writer thread (serializes all writes to stdout)
    thread::Builder::new()
        .name("stdout-writer".to_string())
        .spawn(move || stdout_writer(write_rx))
        .expect("failed to spawn stdout writer");

    // Start the listener thread (register + read NAVIGATE pushes)
    let listener_tx = write_tx.clone();
    let listener_socket = socket_path.to_string();
    let listener_tid = tenant_id.clone();
    thread::Builder::new()
        .name("listener".to_string())
        .spawn(move || listener_loop(&listener_socket, &listener_tid, listener_tx))
        .expect("failed to spawn listener thread");

    // Main thread: read stdin commands, forward to daemon
    stdin_command_loop(socket_path, &tenant_id, write_tx);
}

/// Read JSON messages from stdin, send each as a command to the daemon,
/// and forward responses to the stdout writer.
fn stdin_command_loop(socket_path: &str, tenant_id: &TenantId, write_tx: mpsc::Sender<Value>) {
    let stdin = io::stdin();
    let mut stdin = stdin.lock();

    loop {
        let message = match framing::read_message(&mut stdin) {
            Ok(msg) => msg,
            Err(error) => {
                tracing::debug!(%error, "stdin read failed, exiting");
                break;
            }
        };

        tracing::trace!(message = %message, "received command from extension");

        let command_line = match translate::json_to_command(&message, tenant_id) {
            Ok(cmd) => cmd,
            Err(error) => {
                tracing::warn!(%error, "failed to translate command");
                let err_json = serde_json::json!({"status": "ERR", "message": error.to_string()});
                let _ = write_tx.send(err_json);
                continue;
            }
        };

        let response_json = match send_oneshot_command(socket_path, &command_line) {
            Ok(json) => json,
            Err(error) => {
                tracing::error!(%error, "failed to send command to daemon");
                serde_json::json!({"status": "ERR", "message": error.to_string()})
            }
        };

        if write_tx.send(response_json).is_err() {
            break;
        }
    }
}

/// Send a single command to the daemon and return the response as JSON.
fn send_oneshot_command(
    socket_path: &str,
    command_line: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;

    let line = format!("{command_line}\n");
    stream.write_all(line.as_bytes())?;
    stream.flush()?;

    let mut reader = BufReader::new(&stream);
    let mut response_line = String::new();
    reader.read_line(&mut response_line)?;

    let json = translate::response_to_json(response_line.trim())?;
    Ok(json)
}

/// Long-lived listener loop: registers with the daemon and reads NAVIGATE pushes.
/// Reconnects with exponential backoff on failure.
fn listener_loop(socket_path: &str, tenant_id: &TenantId, write_tx: mpsc::Sender<Value>) {
    let mut backoff = Duration::from_millis(100);
    let max_backoff = Duration::from_secs(30);

    loop {
        match run_listener_connection(socket_path, tenant_id, &write_tx) {
            Ok(()) => {
                tracing::info!("listener connection closed normally");
                break; // Clean shutdown
            }
            Err(error) => {
                tracing::warn!(%error, backoff_ms = backoff.as_millis() as u64, "listener disconnected, reconnecting");
                thread::sleep(backoff);
                backoff = (backoff * 2).min(max_backoff);
            }
        }
    }
}

/// Run a single listener connection: register, then read NAVIGATE pushes.
fn run_listener_connection(
    socket_path: &str,
    tenant_id: &TenantId,
    write_tx: &mpsc::Sender<Value>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut stream = UnixStream::connect(socket_path)?;

    // Send register command
    let register_line = format!("register {tenant_id}\n");
    stream.write_all(register_line.as_bytes())?;
    stream.flush()?;

    // Read register response
    let mut reader = BufReader::new(&stream);
    let mut response = String::new();
    reader.read_line(&mut response)?;

    let response = response.trim();
    if response != "OK" {
        return Err(format!("register failed: {response}").into());
    }

    tracing::info!(tenant = %tenant_id, "registered with daemon");

    // Read NAVIGATE pushes
    loop {
        let mut line = String::new();
        let bytes_read = reader.read_line(&mut line)?;
        if bytes_read == 0 {
            return Err("connection closed by daemon".into());
        }

        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        tracing::trace!(line = line, "received push from daemon");

        match translate::parse_server_push(line) {
            Ok(url) => {
                let json = translate::navigate_to_json(&url);
                if write_tx.send(json).is_err() {
                    return Ok(()); // Stdout writer gone, exit cleanly
                }
            }
            Err(error) => {
                tracing::warn!(%error, line = line, "failed to parse push message");
            }
        }
    }
}

/// Write JSON messages to stdout using native messaging framing.
/// Runs in a dedicated thread to serialize concurrent writes.
fn stdout_writer(rx: mpsc::Receiver<Value>) {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();

    for value in rx.iter() {
        if let Err(error) = framing::write_message(&mut stdout, &value) {
            tracing::error!(%error, "failed to write to stdout");
            break;
        }
    }
}
