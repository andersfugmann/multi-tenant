//! CLI argument parsing and subcommand dispatch.
//!
//! Uses `clap::Parser` for argument definitions.

pub mod client;
pub mod setup;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "url-router", about = "Multi-tenant URL routing daemon and CLI")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Start the URL router daemon
    Daemon {
        /// Tenant ID for this daemon instance
        #[arg(long)]
        tenant: String,
        /// Log level (trace, debug, info, warn, error)
        #[arg(long, default_value = "info")]
        log_level: String,
        /// Path to config file
        #[arg(long, default_value = "/etc/url-router/config.json")]
        config: String,
    },
    /// Open a URL (sends open-on default to daemon)
    Open {
        /// URL to open
        url: String,
        /// Socket path (auto-detected from config if not specified)
        #[arg(long)]
        socket: Option<String>,
        /// Path to config file (used to find socket path)
        #[arg(long, default_value = "/etc/url-router/config.json")]
        config: String,
    },
    /// Test which tenant a URL routes to (dry-run)
    Test {
        /// URL to test
        url: String,
        /// Socket path
        #[arg(long)]
        socket: Option<String>,
        /// Path to config file
        #[arg(long, default_value = "/etc/url-router/config.json")]
        config: String,
    },
    /// Show daemon health status
    Status {
        /// Socket path
        #[arg(long)]
        socket: Option<String>,
        /// Path to config file
        #[arg(long, default_value = "/etc/url-router/config.json")]
        config: String,
    },
    /// Set up url-router for a tenant (enable service, install handlers)
    Setup {
        /// Tenant ID
        #[arg(long)]
        tenant: String,
        /// Path to config file
        #[arg(long, default_value = "/etc/url-router/config.json")]
        config: String,
    },
}
