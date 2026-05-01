//! Daemon module — Unix socket listener and connection handling.
//!
//! This module contains the I/O boundary: socket accept loop, thread spawning,
//! and dispatching parsed commands to pure handler functions.

pub mod handler;
pub mod server;
