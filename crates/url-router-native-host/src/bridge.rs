//! Bridge between stdin/stdout and daemon Unix socket.
//!
//! Handles the actual I/O of sending line commands to the daemon
//! and reading line responses.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

/// Send a line command to the daemon socket.
pub fn send_line(stream: &mut UnixStream, line: &str) -> std::io::Result<()> {
    writeln!(stream, "{line}")?;
    stream.flush()
}

/// Read a line response from the daemon socket.
///
/// Creates a fresh BufReader per message since the stream is shared
/// between send_line (write) and read_line (read).
pub fn read_line(stream: &mut UnixStream) -> std::io::Result<String> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    Ok(line.trim().to_string())
}
