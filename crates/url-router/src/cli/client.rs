//! Client-side socket communication.
//!
//! Used by CLI subcommands to send a single command to the daemon and read the response.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// Send a single command line to the daemon and return the response line.
pub fn send_command(socket_path: &str, command: &str) -> Result<String, std::io::Error> {
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;

    writeln!(stream, "{command}")?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    let mut response = String::new();
    reader.read_line(&mut response)?;

    Ok(response.trim().to_string())
}
