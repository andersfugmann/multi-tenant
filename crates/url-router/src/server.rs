//! Socket accept loop and connection handling.
//!
//! Listens on a Unix domain socket, spawning a thread per connection.
//! Each connection thread reads one protocol line, forwards the parsed
//! command to the coordinator via mpsc, waits for the oneshot response,
//! and writes it back to the socket. Register connections are handled
//! specially: the stream is transferred to the coordinator for pushes.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;
use std::thread;

use url_router_protocol::protocol::{Command, Response};
use url_router_protocol::types::TenantId;

use crate::coordinator::CoordinatorMessage;
use crate::oneshot;

/// Bind and run the accept loop on the given socket path.
///
/// Spawns a thread per connection. Blocks forever (or until the listener errors).
pub fn run_accept_loop(listener: UnixListener, coordinator_tx: mpsc::Sender<CoordinatorMessage>) {
    tracing::info!("accept loop started");

    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(error) => {
                tracing::error!(%error, "failed to accept connection");
                continue;
            }
        };

        let tx = coordinator_tx.clone();
        thread::spawn(move || {
            if let Err(error) = handle_connection(stream, tx) {
                tracing::debug!(%error, "connection handler error");
            }
        });
    }
}

/// Create and bind a Unix listener, removing any stale socket file first.
pub fn bind_listener(socket_path: &str) -> Result<UnixListener, std::io::Error> {
    // Remove stale socket file if it exists
    if std::path::Path::new(socket_path).exists() {
        std::fs::remove_file(socket_path)?;
    }

    // Ensure parent directory exists
    if let Some(parent) = std::path::Path::new(socket_path).parent() {
        std::fs::create_dir_all(parent)?;
    }

    let listener = UnixListener::bind(socket_path)?;
    tracing::info!(path = socket_path, "listening on socket");
    Ok(listener)
}

fn handle_connection(
    stream: UnixStream,
    coordinator_tx: mpsc::Sender<CoordinatorMessage>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;

    let line = line.trim_end();
    if line.is_empty() {
        return Ok(());
    }

    tracing::trace!(line = line, "received command");

    let command: Command = line.parse().map_err(|e| {
        // Try to write error response before returning
        let _ = write_response(
            &stream,
            &Response::Error {
                message: format!("parse error: {e}"),
            },
        );
        e
    })?;

    match command {
        Command::Register { tenant_id } => {
            handle_register(stream, tenant_id, coordinator_tx)?;
        }
        other => {
            handle_oneshot_command(stream, other, coordinator_tx)?;
        }
    }

    Ok(())
}

fn handle_oneshot_command(
    stream: UnixStream,
    command: Command,
    coordinator_tx: mpsc::Sender<CoordinatorMessage>,
) -> Result<(), Box<dyn std::error::Error>> {
    let (respond_tx, respond_rx) = oneshot::channel();

    coordinator_tx.send(CoordinatorMessage::Command {
        command,
        respond: respond_tx,
    })?;

    let response = respond_rx.recv()?;
    write_response(&stream, &response)?;

    Ok(())
}

fn handle_register(
    stream: UnixStream,
    tenant_id: TenantId,
    coordinator_tx: mpsc::Sender<CoordinatorMessage>,
) -> Result<(), Box<dyn std::error::Error>> {
    // Clone stream: one for the coordinator (to write NAVIGATE pushes),
    // one for this thread (to detect disconnection).
    let writer_stream = stream.try_clone()?;
    let reader_stream = stream;

    let (respond_tx, respond_rx) = oneshot::channel();

    coordinator_tx.send(CoordinatorMessage::Register {
        tenant_id: tenant_id.clone(),
        stream: writer_stream,
        respond: respond_tx,
    })?;

    let response = respond_rx.recv()?;
    write_response(&reader_stream, &response)?;

    if !matches!(response, Response::Ok) {
        return Ok(());
    }

    // Block on reading to detect disconnection.
    // The registered connection only receives pushes (written by coordinator).
    // When the remote end disconnects, read will return 0 bytes / EOF.
    tracing::debug!(tenant = %tenant_id, "registered connection, waiting for disconnect");
    let mut reader = BufReader::new(reader_stream);
    let mut buf = String::new();
    loop {
        buf.clear();
        match reader.read_line(&mut buf) {
            Ok(0) | Err(_) => break, // EOF or error = disconnected
            Ok(_) => {
                // Registered connections shouldn't send data; ignore it
                tracing::trace!(tenant = %tenant_id, data = buf.trim(), "unexpected data on registered connection");
            }
        }
    }

    let _ = coordinator_tx.send(CoordinatorMessage::Unregister { tenant_id });
    Ok(())
}

fn write_response(mut stream: &UnixStream, response: &Response) -> Result<(), std::io::Error> {
    let line = format!("{response}\n");
    stream.write_all(line.as_bytes())?;
    stream.flush()?;
    Ok(())
}
