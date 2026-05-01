//! Logging initialization for the url-router daemon and CLI.
//!
//! Configures the `tracing` subscriber with configurable verbosity
//! and journal-compatible output format.

use tracing_subscriber::EnvFilter;

/// Initialize the tracing subscriber with the given log level.
///
/// The level can be overridden by the `RUST_LOG` environment variable.
/// If neither is set, defaults to `info`.
pub fn init(level: Option<&str>) {
    let default_level = level.unwrap_or("info");
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(default_level));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .init();
}
