//! Configuration file I/O and watching.
//!
//! Reads configuration from disk using `url_router_protocol::config` for
//! parsing, and watches for file changes using the `notify` crate to trigger
//! live reloads.

use std::path::{Path, PathBuf};
use std::sync::mpsc;

use notify::{EventKind, RecursiveMode, Watcher};
use thiserror::Error;
use url_router_protocol::config::{Config, ConfigError};

use crate::coordinator::CoordinatorMessage;

/// Errors from config I/O operations.
#[derive(Debug, Error)]
pub enum ConfigIoError {
    #[error("failed to read config file: {0}")]
    Read(#[from] std::io::Error),

    #[error("failed to parse config: {0}")]
    Parse(#[from] ConfigError),

    #[error("failed to set up file watcher: {0}")]
    Watch(#[from] notify::Error),
}

/// Read and parse configuration from a file.
pub fn read_config(path: &Path) -> Result<Config, ConfigIoError> {
    let content = std::fs::read_to_string(path)?;
    let config = Config::from_json(&content)?;
    Ok(config)
}

/// Watch a config file for changes and send `ConfigReloaded` messages to the coordinator.
///
/// This function blocks forever, monitoring the file for modifications. When
/// the file changes, it re-reads and re-parses the config, forwarding
/// successful parses to the coordinator. Parse errors are logged as warnings.
///
/// Watches the parent directory to handle editors that write-and-rename.
pub fn watch_config(
    path: PathBuf,
    coordinator_tx: mpsc::Sender<CoordinatorMessage>,
) -> Result<(), ConfigIoError> {
    let (tx, rx) = mpsc::channel();

    let mut watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
        if let Ok(event) = result {
            if matches!(
                event.kind,
                EventKind::Modify(_) | EventKind::Create(_) | EventKind::Remove(_)
            ) {
                let _ = tx.send(());
            }
        }
    })?;

    // Watch the parent directory to catch atomic rename patterns
    let watch_dir = path.parent().unwrap_or(Path::new("."));
    watcher.watch(watch_dir, RecursiveMode::NonRecursive)?;

    tracing::info!(path = %path.display(), "watching config file for changes");

    for () in rx.iter() {
        // Debounce: drain any queued events
        while rx.try_recv().is_ok() {}

        if !path.exists() {
            tracing::warn!(path = %path.display(), "config file removed");
            continue;
        }

        match read_config(&path) {
            Ok(config) => {
                tracing::info!(path = %path.display(), "config reloaded");
                let _ = coordinator_tx.send(CoordinatorMessage::ConfigReloaded { config });
            }
            Err(error) => {
                tracing::warn!(%error, path = %path.display(), "failed to reload config");
            }
        }
    }

    Ok(())
}
