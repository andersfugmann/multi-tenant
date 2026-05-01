//! Configuration types for the url-router system.
//!
//! Defines the JSON configuration schema: tenants, routing rules, and defaults.
//! Pure parsing only — no file I/O. Use `Config::from_json` to parse a config string.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::types::TenantId;

/// Top-level configuration for the URL router.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Config {
    pub tenants: HashMap<String, Tenant>,
    pub rules: Vec<Rule>,
    #[serde(default)]
    pub defaults: Defaults,
}

impl Config {
    /// Parse a config from a JSON string.
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    /// Serialize the config to a JSON string.
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    /// Serialize the config to a pretty-printed JSON string.
    pub fn to_json_pretty(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// Return an iterator over rules that are enabled.
    pub fn active_rules(&self) -> impl Iterator<Item = (usize, &Rule)> {
        self.rules
            .iter()
            .enumerate()
            .filter(|(_, rule)| rule.is_enabled())
    }

    /// Look up a tenant by ID. Returns `None` if the tenant doesn't exist.
    pub fn tenant(&self, id: &str) -> Option<&Tenant> {
        self.tenants.get(id)
    }
}

/// A tenant in the routing system.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tenant {
    pub name: String,
    pub browser_cmd: String,
    pub socket: String,
    #[serde(default)]
    pub badge_label: Option<String>,
    #[serde(default)]
    pub badge_color: Option<String>,
}

/// A URL routing rule.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Rule {
    pub pattern: String,
    pub tenant: TenantId,
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub comment: Option<String>,
}

impl Rule {
    /// Whether this rule is active. Defaults to `true` if `enabled` is not specified.
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
}

/// Default behavior settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Defaults {
    /// What to do when no rule matches: "local" (keep in current tenant) or a tenant ID.
    #[serde(default = "Defaults::default_unmatched")]
    pub unmatched: String,
    /// Whether to show desktop notifications on routing decisions.
    #[serde(default = "Defaults::default_notifications")]
    pub notifications: bool,
    /// Timeout for desktop notifications in milliseconds.
    #[serde(default = "Defaults::default_notification_timeout_ms")]
    pub notification_timeout_ms: u32,
}

impl Defaults {
    fn default_unmatched() -> String {
        "local".to_string()
    }

    fn default_notifications() -> bool {
        true
    }

    fn default_notification_timeout_ms() -> u32 {
        3000
    }
}

impl Default for Defaults {
    fn default() -> Self {
        Self {
            unmatched: Self::default_unmatched(),
            notifications: Self::default_notifications(),
            notification_timeout_ms: Self::default_notification_timeout_ms(),
        }
    }
}

/// A rule definition for the `add-rule` command (JSON payload).
/// Same shape as `Rule` but used specifically for the add-rule protocol command.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RuleDefinition {
    pub pattern: String,
    pub tenant: TenantId,
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub comment: Option<String>,
}

impl From<RuleDefinition> for Rule {
    fn from(def: RuleDefinition) -> Self {
        Self {
            pattern: def.pattern,
            tenant: def.tenant,
            enabled: def.enabled,
            comment: def.comment,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXAMPLE_CONFIG: &str = r##"{
        "tenants": {
            "host": {
                "name": "Personal",
                "browser_cmd": "microsoft-edge",
                "socket": "/run/url-router/host.sock",
                "badge_label": "P",
                "badge_color": "#4285f4"
            },
            "work": {
                "name": "Work",
                "browser_cmd": "chromium",
                "socket": "/run/url-router/work.sock",
                "badge_label": "W",
                "badge_color": "#34a853"
            }
        },
        "rules": [
            {
                "pattern": "^https?://(www\\.)?github\\.com(/|$)",
                "tenant": "host",
                "comment": "GitHub to personal"
            },
            {
                "pattern": "^https?://.*\\.office\\.com(/|$)",
                "tenant": "work"
            },
            {
                "pattern": "^https?://disabled\\.example\\.com",
                "tenant": "work",
                "enabled": false
            }
        ],
        "defaults": {
            "unmatched": "local",
            "notifications": true,
            "notification_timeout_ms": 3000
        }
    }"##;

    #[test]
    fn parse_example_config() {
        let config = Config::from_json(EXAMPLE_CONFIG).unwrap();
        assert_eq!(config.tenants.len(), 2);
        assert_eq!(config.rules.len(), 3);
        assert_eq!(config.tenants["host"].name, "Personal");
        assert_eq!(config.tenants["work"].browser_cmd, "chromium");
    }

    #[test]
    fn active_rules_skip_disabled() {
        let config = Config::from_json(EXAMPLE_CONFIG).unwrap();
        let active: Vec<_> = config.active_rules().collect();
        assert_eq!(active.len(), 2);
        assert_eq!(active[0].0, 0); // index 0
        assert_eq!(active[1].0, 1); // index 1 (index 2 is disabled)
    }

    #[test]
    fn roundtrip_json() {
        let config = Config::from_json(EXAMPLE_CONFIG).unwrap();
        let json = config.to_json().unwrap();
        let reparsed = Config::from_json(&json).unwrap();
        assert_eq!(config, reparsed);
    }

    #[test]
    fn defaults_when_missing() {
        let json = r#"{
            "tenants": {},
            "rules": []
        }"#;
        let config = Config::from_json(json).unwrap();
        assert_eq!(config.defaults.unmatched, "local");
        assert!(config.defaults.notifications);
        assert_eq!(config.defaults.notification_timeout_ms, 3000);
    }

    #[test]
    fn rule_definition_into_rule() {
        let def = RuleDefinition {
            pattern: "^https://example.com".into(),
            tenant: TenantId::new("work"),
            enabled: None,
            comment: Some("test".into()),
        };
        let rule: Rule = def.into();
        assert!(rule.is_enabled());
        assert_eq!(rule.comment.as_deref(), Some("test"));
    }
}
