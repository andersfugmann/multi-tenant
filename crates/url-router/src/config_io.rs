//! Config file I/O — reading, writing, and watching.
//!
//! Uses `url_router_protocol::config` for parsing. This module handles
//! the file system operations: reading from disk, writing with flock,
//! and watching for changes with inotify.

use std::fs;
use std::path::Path;
use std::sync::{Arc, RwLock};

use tracing::{error, info};
use url_router_protocol::config::{Config, Rule};

/// Read and parse the config file from disk.
pub fn load_config(path: &str) -> Result<Config, ConfigIoError> {
    let content = fs::read_to_string(path).map_err(ConfigIoError::Read)?;
    Config::from_json(&content).map_err(ConfigIoError::Parse)
}

/// Append a rule to the config file using file locking.
///
/// Reads the current config, appends the rule, and writes it back
/// while holding an exclusive flock to prevent concurrent writes.
pub fn add_rule(config_path: &str, rule: Rule) -> Result<(), ConfigIoError> {
    use std::os::unix::io::AsRawFd;

    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(config_path)
        .map_err(ConfigIoError::Read)?;

    // Acquire exclusive lock
    let fd = file.as_raw_fd();
    let ret = unsafe { libc::flock(fd, libc::LOCK_EX) };
    if ret != 0 {
        return Err(ConfigIoError::Lock(std::io::Error::last_os_error()));
    }

    // Read current config
    let content = fs::read_to_string(config_path).map_err(ConfigIoError::Read)?;
    let mut config = Config::from_json(&content).map_err(ConfigIoError::Parse)?;

    // Append rule
    config.rules.push(rule);

    // Write back
    let json = config.to_json_pretty().map_err(ConfigIoError::Serialize)?;
    fs::write(config_path, json.as_bytes()).map_err(ConfigIoError::Write)?;

    // Lock released when file is dropped
    Ok(())
}

/// Start a config watcher thread that reloads config on file changes.
///
/// Uses the `notify` crate (inotify on Linux) to watch for modifications.
/// Updates the shared config state when the file changes.
pub fn watch_config(config_path: String, config: Arc<RwLock<Config>>) -> Result<(), ConfigIoError> {
    use notify::{Event, EventKind, RecursiveMode, Watcher};
    use std::sync::mpsc;

    let (tx, rx) = mpsc::channel::<notify::Result<Event>>();

    let mut watcher =
        notify::recommended_watcher(tx).map_err(|e| ConfigIoError::Watch(e.to_string()))?;

    // Watch the parent directory (inotify needs the directory for renamed files)
    let parent = Path::new(&config_path)
        .parent()
        .unwrap_or(Path::new("/etc/url-router"));

    watcher
        .watch(parent, RecursiveMode::NonRecursive)
        .map_err(|e| ConfigIoError::Watch(e.to_string()))?;

    let config_path_clone = config_path.clone();
    std::thread::spawn(move || {
        // Keep watcher alive
        let _watcher = watcher;

        for event in rx {
            match event {
                Ok(Event {
                    kind: EventKind::Modify(_) | EventKind::Create(_),
                    ..
                }) => {
                    reload_config(&config_path_clone, &config);
                }
                Err(e) => {
                    error!(error = %e, "config watcher error");
                }
                _ => {}
            }
        }
    });

    Ok(())
}

fn reload_config(path: &str, config: &Arc<RwLock<Config>>) {
    match load_config(path) {
        Ok(new_config) => {
            let mut guard = config.write().unwrap();
            *guard = new_config;
            info!(path = path, "config reloaded");
        }
        Err(e) => {
            error!(path = path, error = %e, "failed to reload config");
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigIoError {
    #[error("failed to read config: {0}")]
    Read(std::io::Error),
    #[error("failed to parse config: {0}")]
    Parse(serde_json::Error),
    #[error("failed to serialize config: {0}")]
    Serialize(serde_json::Error),
    #[error("failed to write config: {0}")]
    Write(std::io::Error),
    #[error("failed to lock config: {0}")]
    Lock(std::io::Error),
    #[error("failed to watch config: {0}")]
    Watch(String),
}
