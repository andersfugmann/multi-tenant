//! URL router client — dual-mode binary.
//!
//! When invoked with no arguments (or with a `chrome-extension://` origin),
//! runs as a Chrome native messaging host. When invoked with CLI arguments,
//! runs as a command-line client for the daemon.

mod bridge;
mod cli;
mod framing;
mod translate;

use clap::Parser;
use url_router_protocol::config::DEFAULT_SOCKET_PATH;
use url_router_protocol::types::TenantId;

fn main() {
    if is_native_messaging_mode() {
        init_logging();
        native_messaging_mode();
    } else {
        init_logging();
        cli_mode();
    }
}

/// Determine if we should run in native messaging mode.
///
/// Chrome spawns native messaging hosts with the extension origin as the
/// sole argument. We treat no args or a `chrome-extension://` arg as
/// native messaging mode; anything else is CLI mode.
fn is_native_messaging_mode() -> bool {
    let args: Vec<String> = std::env::args().collect();
    args.len() == 1
        || args
            .get(1)
            .is_some_and(|a| a.starts_with("chrome-extension://"))
}

fn native_messaging_mode() {
    let socket_path =
        std::env::var("URL_ROUTER_SOCKET").unwrap_or_else(|_| DEFAULT_SOCKET_PATH.to_string());

    let tenant_id = TenantId::from(get_hostname());
    tracing::info!(tenant = %tenant_id, socket = %socket_path, "starting native messaging mode");

    bridge::run(&socket_path, tenant_id);
}

fn cli_mode() {
    let cli = cli::Cli::parse();
    if let Err(error) = cli::run(cli) {
        tracing::error!(%error, "command failed");
        std::process::exit(1);
    }
}

fn init_logging() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .init();
}

/// Read the system hostname from /proc or /etc.
fn get_hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .or_else(|_| std::fs::read_to_string("/etc/hostname"))
        .unwrap_or_else(|_| "unknown".to_string())
        .trim()
        .to_string()
}
