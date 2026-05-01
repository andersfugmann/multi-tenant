//! Browser process launching.
//!
//! Thin wrapper around `std::process::Command` for launching the browser.
//! The browser is spawned as a detached process that outlives the daemon.

use std::process::Command;

/// Launch a browser with the given command and URL.
///
/// The browser process is spawned detached (stdin/stdout/stderr are null)
/// so it doesn't block the daemon or die when the daemon stops.
pub fn launch(browser_cmd: &str, url: &str) -> std::io::Result<()> {
    Command::new(browser_cmd)
        .arg(url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    Ok(())
}
