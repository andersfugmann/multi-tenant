//! Shared newtypes for domain concepts.
//!
//! These types enforce type safety at compile time, preventing accidental
//! misuse of raw strings and integers that represent distinct domain concepts.

use derive_more::{Display, From, FromStr};
use serde::{Deserialize, Serialize};

/// Identifies a tenant in the multi-tenant routing system.
///
/// Tenant IDs correspond to hostnames and must contain only alphanumeric
/// characters, hyphens, and dots. The special values `"default"` (CLI synthetic
/// tenant) and `"local"` (no routing) are valid but carry distinct semantics.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Display, From, FromStr)]
pub struct TenantId(String);

impl TenantId {
    /// Returns the tenant ID as a string slice.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Returns true if this tenant ID contains only allowed characters
    /// (alphanumeric, hyphens, dots) and is non-empty.
    pub fn is_valid(&self) -> bool {
        !self.0.is_empty()
            && self
                .0
                .chars()
                .all(|c| c.is_alphanumeric() || c == '-' || c == '.')
    }

    /// Returns true if this is the synthetic `"default"` tenant used by CLI commands.
    pub fn is_default(&self) -> bool {
        self.0 == "default"
    }

    /// Returns true if this represents local handling (no routing).
    pub fn is_local(&self) -> bool {
        self.0 == "local"
    }
}

/// Zero-based index of a rule in the configuration's rule list.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Display, From, FromStr,
)]
pub struct RuleIndex(usize);

impl RuleIndex {
    /// Returns the underlying index value.
    pub fn value(self) -> usize {
        self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tenant_id_valid_alphanumeric() {
        let tid = TenantId::from("my-host.local".to_string());
        assert!(tid.is_valid());
    }

    #[test]
    fn tenant_id_invalid_spaces() {
        let tid = TenantId::from("my host".to_string());
        assert!(!tid.is_valid());
    }

    #[test]
    fn tenant_id_invalid_empty() {
        let tid = TenantId::from(String::new());
        assert!(!tid.is_valid());
    }

    #[test]
    fn tenant_id_special_values() {
        assert!(TenantId::from("default".to_string()).is_default());
        assert!(TenantId::from("local".to_string()).is_local());
        assert!(!TenantId::from("myhost".to_string()).is_default());
        assert!(!TenantId::from("myhost".to_string()).is_local());
    }

    #[test]
    fn tenant_id_display_roundtrip() {
        let tid = TenantId::from("work-container".to_string());
        let s = tid.to_string();
        let parsed: TenantId = s.parse().unwrap();
        assert_eq!(tid, parsed);
    }

    #[test]
    fn rule_index_display_roundtrip() {
        let idx = RuleIndex::from(42);
        let s = idx.to_string();
        let parsed: RuleIndex = s.parse().unwrap();
        assert_eq!(idx, parsed);
        assert_eq!(idx.value(), 42);
    }
}
