//! Browser process launching.
//!
//! Thin wrapper around `std::process::Command` for spawning browser processes.
//! The browser command string is split on whitespace, with the URL appended
//! as the final argument.

use std::process::{Child, Command, Stdio};

use thiserror::Error;

/// Errors from browser launching.
#[derive(Debug, Error)]
pub enum BrowserError {
    #[error("empty browser command")]
    EmptyCommand,

    #[error("failed to spawn browser: {0}")]
    Spawn(#[from] std::io::Error),
}

/// Spawn a browser process with the given URL.
///
/// The `browser_cmd` is split on whitespace to form the program and arguments,
/// with `url` appended as the final argument. The child process is fully
/// detached (stdin/stdout/stderr are null).
pub fn launch_browser(browser_cmd: &str, url: &str) -> Result<Child, BrowserError> {
    let parts: Vec<&str> = browser_cmd.split_whitespace().collect();
    let (program, args) = parts.split_first().ok_or(BrowserError::EmptyCommand)?;

    let child = Command::new(program)
        .args(args)
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    Ok(child)
}
