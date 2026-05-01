//! Shared newtypes for domain concepts.
//!
//! These types prevent mixing up strings that represent different things
//! (e.g., passing a URL where a tenant ID is expected).

use derive_more::{Display, From};
use serde::{Deserialize, Serialize};

/// Identifies a tenant in the routing system (e.g., "host", "work").
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Display, From)]
#[serde(transparent)]
pub struct TenantId(String);

impl TenantId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The special tenant ID "default" means "evaluate rules to determine the correct tenant".
    pub fn is_default(&self) -> bool {
        self.0 == "default"
    }
}

/// Zero-based index of a rule in the config's rule list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Display, From)]
#[serde(transparent)]
pub struct RuleIndex(pub usize);
