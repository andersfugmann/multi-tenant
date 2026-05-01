mod browser;
mod cli;
mod config_io;
mod daemon;
mod forwarding;
mod logging;
mod notification;

use std::path::Path;
use std::process;
use std::sync::{Arc, RwLock};
use std::time::Instant;

use clap::Parser;
use tracing::{error, info};
use url_router_protocol::types::TenantId;

use cli::{Cli, Commands};
use daemon::server::DaemonState;

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Commands::Daemon {
            tenant,
            log_level,
            config,
        } => run_daemon(&tenant, &log_level, &config),
        Commands::Open {
            url,
            socket,
            config,
        } => run_open(&url, socket.as_deref(), &config),
        Commands::Test {
            url,
            socket,
            config,
        } => run_test(&url, socket.as_deref(), &config),
        Commands::Status { socket, config } => run_status(socket.as_deref(), &config),
        Commands::Setup { tenant, config } => cli::setup::run(&tenant, &config),
    }
}

fn run_daemon(tenant: &str, log_level: &str, config_path: &str) {
    logging::init(Some(log_level));

    let config = match config_io::load_config(config_path) {
        Ok(c) => c,
        Err(e) => {
            error!(error = %e, "failed to load config");
            process::exit(1);
        }
    };

    let tenant_id = TenantId::new(tenant);

    // Verify tenant exists in config
    if config.tenant(tenant).is_none() {
        error!(tenant = tenant, "tenant not found in config");
        process::exit(1);
    }

    let socket_path = config.tenant(tenant).unwrap().socket.clone();
    let config = Arc::new(RwLock::new(config));

    // Start config watcher
    if let Err(e) = config_io::watch_config(config_path.to_string(), Arc::clone(&config)) {
        error!(error = %e, "failed to start config watcher");
        // Non-fatal: continue without hot-reload
    }

    let state = Arc::new(DaemonState {
        config,
        tenant: tenant_id,
        config_path: config_path.to_string(),
        start_time: Instant::now(),
    });

    info!(tenant = tenant, socket = %socket_path, "starting daemon");

    if let Err(e) = daemon::server::run(Path::new(&socket_path), state) {
        error!(error = %e, "daemon failed");
        process::exit(1);
    }
}

/// Resolve the socket path: use explicit --socket, or read config to find local tenant socket.
fn resolve_socket(explicit: Option<&str>, config_path: &str) -> String {
    if let Some(s) = explicit {
        return s.to_string();
    }

    // Try to find the local tenant's socket from config
    // Use hostname-based heuristic or first available socket
    match config_io::load_config(config_path) {
        Ok(config) => {
            // Try each tenant's socket to see which one exists
            for (_, tenant) in &config.tenants {
                if Path::new(&tenant.socket).exists() {
                    return tenant.socket.clone();
                }
            }
            // Fallback
            eprintln!("error: no reachable daemon socket found. Use --socket to specify.");
            process::exit(1);
        }
        Err(e) => {
            eprintln!("error: failed to read config: {e}. Use --socket to specify.");
            process::exit(1);
        }
    }
}

fn run_open(url: &str, socket: Option<&str>, config_path: &str) {
    let socket_path = resolve_socket(socket, config_path);
    let cmd = format!("open-on default {url}");

    match cli::client::send_command(&socket_path, &cmd) {
        Ok(response) => println!("{response}"),
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    }
}

fn run_test(url: &str, socket: Option<&str>, config_path: &str) {
    let socket_path = resolve_socket(socket, config_path);
    let cmd = format!("test {url}");

    match cli::client::send_command(&socket_path, &cmd) {
        Ok(response) => println!("{response}"),
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    }
}

fn run_status(socket: Option<&str>, config_path: &str) {
    let socket_path = resolve_socket(socket, config_path);

    match cli::client::send_command(&socket_path, "status") {
        Ok(response) => println!("{response}"),
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    }
}

