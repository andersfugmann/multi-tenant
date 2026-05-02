//! CLI mode for direct daemon interaction.
//!
//! Provides a command-line interface for sending individual commands to the
//! daemon and printing responses. Used for testing and administration.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use clap::{Parser, Subcommand};
use thiserror::Error;
use url_router_protocol::config::DEFAULT_SOCKET_PATH;

/// Errors from CLI operations.
#[derive(Debug, Error)]
pub enum CliError {
    #[error("failed to connect to daemon: {0}")]
    Connect(#[from] std::io::Error),
}

#[derive(Parser)]
#[command(
    name = "url-router-client",
    about = "URL router client and native messaging host"
)]
pub struct Cli {
    /// Path to the daemon socket
    #[arg(
        short,
        long,
        default_value = DEFAULT_SOCKET_PATH
    )]
    pub socket: String,

    #[command(subcommand)]
    pub command: CliCommand,
}

#[derive(Subcommand)]
pub enum CliCommand {
    /// Open a URL (evaluates routing rules)
    Open {
        /// URL to open
        url: String,
    },
    /// Open a URL on a specific tenant
    OpenOn {
        /// Target tenant ID
        tenant: String,
        /// URL to open
        url: String,
    },
    /// Test a URL against routing rules
    Test {
        /// URL to test
        url: String,
    },
    /// Get the current configuration
    GetConfig,
    /// Get daemon status
    Status,
}

/// Run the CLI: connect, send command, print response, exit.
pub fn run(cli: Cli) -> Result<(), CliError> {
    let command_line = match &cli.command {
        CliCommand::Open { url } => format!("open default {url}"),
        CliCommand::OpenOn { tenant, url } => format!("open-on {tenant} {url}"),
        CliCommand::Test { url } => format!("test {url}"),
        CliCommand::GetConfig => "get-config".to_string(),
        CliCommand::Status => "status".to_string(),
    };

    let mut stream = UnixStream::connect(&cli.socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;

    let line = format!("{command_line}\n");
    stream.write_all(line.as_bytes())?;
    stream.flush()?;

    let mut reader = BufReader::new(&stream);
    let mut response = String::new();
    reader.read_line(&mut response)?;

    let response = response.trim();
    println!("{response}");

    Ok(())
}
