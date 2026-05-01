//! Cross-tenant forwarding via peer Unix sockets.
//!
//! Connects to a peer daemon's socket and sends commands.
//! Used when a URL needs to be opened on a different tenant.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ForwardError {
    #[error("failed to connect to peer socket: {0}")]
    Connect(std::io::Error),
    #[error("failed to send command: {0}")]
    Send(std::io::Error),
    #[error("failed to read response: {0}")]
    Receive(std::io::Error),
    #[error("peer returned error: {0}")]
    PeerError(String),
}

/// Forward an `open-local <url>` command to a peer daemon.
///
/// Connects to the peer's socket, sends the command, and reads the response.
/// Returns `Ok(())` if the peer responded with `OK`.
pub fn forward_open_local(socket_path: &str, url: &str) -> Result<(), ForwardError> {
    let mut stream = UnixStream::connect(socket_path).map_err(ForwardError::Connect)?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(ForwardError::Connect)?;

    let cmd = format!("open-local {url}\n");
    stream
        .write_all(cmd.as_bytes())
        .map_err(ForwardError::Send)?;
    stream.flush().map_err(ForwardError::Send)?;

    let mut reader = BufReader::new(stream);
    let mut response = String::new();
    reader
        .read_line(&mut response)
        .map_err(ForwardError::Receive)?;

    let trimmed = response.trim();
    if trimmed == "OK" {
        Ok(())
    } else {
        Err(ForwardError::PeerError(trimmed.to_string()))
    }
}
