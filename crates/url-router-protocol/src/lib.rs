//! Shared types for the url-router multi-tenant URL routing system.
//!
//! This crate provides:
//! - Configuration types (tenants, rules, defaults) with serde derives
//! - URL matching logic (regex-based, first match wins)
//! - Protocol command and response types with FromStr/Display for line format
//! - Shared newtypes (TenantId, RuleIndex)
//!
//! This crate contains no I/O — it is purely data types and pure functions.

pub mod config;
pub mod matching;
pub mod protocol;
pub mod types;
