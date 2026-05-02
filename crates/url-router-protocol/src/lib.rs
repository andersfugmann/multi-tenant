//! Shared types and protocol definitions for the url-router system.
//!
//! This crate is the single source of truth for configuration types,
//! protocol message formats, routing logic, and domain newtypes.
//! It performs no I/O and contains only pure functions and data types.

pub mod config;
pub mod matching;
pub mod protocol;
pub mod types;
