//! Tracing subscriber initialization.
//!
//! Sets up structured logging via the `tracing` crate with an env-filter
//! controlled by the `RUST_LOG` environment variable (defaults to `info`).

use tracing_subscriber::EnvFilter;

/// Initialize the global tracing subscriber.
///
/// Uses `RUST_LOG` environment variable for filtering (defaults to `info`).
/// Must be called once at program start.
pub fn init() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
}
