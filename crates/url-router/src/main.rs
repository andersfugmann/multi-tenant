//! Multi-tenant URL routing daemon.
//!
//! Entry point for the `url-router` binary. Reads configuration, starts the
//! coordinator thread, config file watcher, and socket accept loop.

mod browser;
mod config_io;
mod coordinator;
mod logging;
mod notification;
mod oneshot;
mod server;

use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;

use clap::{Parser, Subcommand};

use crate::coordinator::CoordinatorMessage;

#[derive(Parser)]
#[command(name = "url-router", about = "Multi-tenant URL routing daemon")]
struct Cli {
    #[command(subcommand)]
    command: CliCommand,
}

#[derive(Subcommand)]
enum CliCommand {
    /// Start the routing daemon
    Daemon {
        /// Path to the configuration file
        #[arg(short, long, default_value = "/etc/url-router/config.json")]
        config: PathBuf,
    },
}

fn main() {
    logging::init();

    let cli = Cli::parse();
    match cli.command {
        CliCommand::Daemon {
            config: config_path,
        } => {
            run_daemon(config_path);
        }
    }
}

fn run_daemon(config_path: PathBuf) {
    // Read initial config
    let config = match config_io::read_config(&config_path) {
        Ok(c) => c,
        Err(error) => {
            tracing::error!(%error, path = %config_path.display(), "failed to read config");
            std::process::exit(1);
        }
    };

    let socket_path = config.socket.clone();

    // Create the coordinator channel
    let (coordinator_tx, coordinator_rx) = mpsc::channel::<CoordinatorMessage>();

    // Start the coordinator thread
    let coord_config = config.clone();
    thread::Builder::new()
        .name("coordinator".to_string())
        .spawn(move || {
            coordinator::run_coordinator(coordinator_rx, coord_config);
        })
        .expect("failed to spawn coordinator thread");

    // Start the config watcher thread
    let watcher_tx = coordinator_tx.clone();
    let watcher_path = config_path.clone();
    thread::Builder::new()
        .name("config-watcher".to_string())
        .spawn(move || {
            if let Err(error) = config_io::watch_config(watcher_path, watcher_tx) {
                tracing::error!(%error, "config watcher failed");
            }
        })
        .expect("failed to spawn config watcher thread");

    // Set up signal handling for clean shutdown
    setup_signal_handler(&socket_path);

    // Bind and run the accept loop (blocks on main thread)
    let listener = match server::bind_listener(&socket_path) {
        Ok(l) => l,
        Err(error) => {
            tracing::error!(%error, path = socket_path, "failed to bind socket");
            std::process::exit(1);
        }
    };

    server::run_accept_loop(listener, coordinator_tx);
}

fn setup_signal_handler(socket_path: &str) {
    let path = socket_path.to_string();

    // Handle SIGTERM/SIGINT: remove socket file and exit
    if let Err(error) = ctrlc_handler(&path) {
        tracing::warn!(%error, "failed to set up signal handler");
    }
}

fn ctrlc_handler(socket_path: &str) -> Result<(), Box<dyn std::error::Error>> {
    let path = socket_path.to_string();
    unsafe {
        libc::signal(libc::SIGTERM, handle_signal as libc::sighandler_t);
        libc::signal(libc::SIGINT, handle_signal as libc::sighandler_t);
    }
    // Store path for cleanup — use a simple static
    // For simplicity, we just let the OS clean up. The bind_listener
    // already removes stale sockets on startup.
    let _ = path;
    Ok(())
}

extern "C" fn handle_signal(_sig: libc::c_int) {
    // Exit cleanly; the socket file will be cleaned up on next start
    std::process::exit(0);
}
