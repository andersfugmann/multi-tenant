//! Configuration types for the url-router system.
//!
//! Provides strongly-typed configuration parsed from JSON. All validation
//! happens at parse time via `Config::from_json`, so downstream code can
//! rely on invariants being upheld. This module performs no I/O.

use std::collections::HashMap;

use regex::Regex;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::types::TenantId;

/// Default Unix socket path for the daemon.
pub const DEFAULT_SOCKET_PATH: &str = "/run/url-router/url-router.sock";

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors that can occur when parsing or validating configuration.
#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("JSON parse error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("invalid tenant ID {0:?}: must be alphanumeric, hyphens, and dots")]
    InvalidTenantId(String),

    #[error("reserved tenant ID {0:?}: cannot use \"default\" as a tenant key")]
    ReservedTenantId(String),

    #[error("tenant {0:?} has an empty browser_cmd")]
    EmptyBrowserCmd(String),

    #[error("rule {index} references unknown tenant {tenant:?}")]
    UnknownRuleTenant { index: usize, tenant: String },

    #[error("invalid regex in rule {index}: {source}")]
    InvalidPattern { index: usize, source: regex::Error },

    #[error("defaults.unmatched references unknown tenant {0:?}")]
    InvalidUnmatchedTenant(String),
}

// ---------------------------------------------------------------------------
// Raw deserialization types (private)
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ConfigRaw {
    #[serde(default = "default_socket_path")]
    socket: String,
    #[serde(default)]
    tenants: HashMap<String, TenantRaw>,
    #[serde(default)]
    rules: Vec<RuleRaw>,
    #[serde(default)]
    defaults: DefaultsRaw,
}

#[derive(Deserialize)]
struct TenantRaw {
    browser_cmd: String,
    #[serde(default)]
    badge_label: Option<String>,
    #[serde(default)]
    badge_color: Option<String>,
}

#[derive(Deserialize)]
struct RuleRaw {
    pattern: String,
    tenant: String,
    #[serde(default)]
    enabled: Option<bool>,
}

#[derive(Deserialize)]
struct DefaultsRaw {
    #[serde(default = "default_unmatched")]
    unmatched: String,
    #[serde(default = "default_true")]
    notifications: bool,
    #[serde(default = "default_notification_timeout")]
    notification_timeout_ms: u64,
    #[serde(default = "default_cooldown")]
    cooldown_secs: u64,
    #[serde(default = "default_browser_timeout")]
    browser_launch_timeout_secs: u64,
}

impl Default for DefaultsRaw {
    fn default() -> Self {
        Self {
            unmatched: default_unmatched(),
            notifications: true,
            notification_timeout_ms: default_notification_timeout(),
            cooldown_secs: default_cooldown(),
            browser_launch_timeout_secs: default_browser_timeout(),
        }
    }
}

fn default_socket_path() -> String {
    DEFAULT_SOCKET_PATH.to_string()
}
fn default_unmatched() -> String {
    "local".to_string()
}
fn default_true() -> bool {
    true
}
fn default_notification_timeout() -> u64 {
    3000
}
fn default_cooldown() -> u64 {
    5
}
fn default_browser_timeout() -> u64 {
    15
}

// ---------------------------------------------------------------------------
// Public validated types
// ---------------------------------------------------------------------------

/// Top-level configuration for the url-router daemon.
#[derive(Debug, Clone, Serialize)]
pub struct Config {
    pub socket: String,
    pub tenants: HashMap<TenantId, Tenant>,
    pub rules: Vec<Rule>,
    pub defaults: Defaults,
}

/// Configuration for a single tenant (browser instance).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tenant {
    pub browser_cmd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge_label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge_color: Option<String>,
}

/// A URL routing rule with a compiled regex pattern.
#[derive(Debug, Clone, Serialize)]
pub struct Rule {
    pub pattern: String,
    #[serde(skip)]
    compiled: Regex,
    pub tenant: TenantId,
    pub enabled: bool,
}

impl Rule {
    /// Tests whether the given URL matches this rule's pattern.
    pub fn is_match(&self, url: &str) -> bool {
        self.compiled.is_match(url)
    }
}

impl PartialEq for Rule {
    fn eq(&self, other: &Self) -> bool {
        self.pattern == other.pattern
            && self.tenant == other.tenant
            && self.enabled == other.enabled
    }
}

/// Global default settings for the daemon.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Defaults {
    pub unmatched: TenantId,
    pub notifications: bool,
    pub notification_timeout_ms: u64,
    pub cooldown_secs: u64,
    pub browser_launch_timeout_secs: u64,
}

// ---------------------------------------------------------------------------
// Parsing and validation
// ---------------------------------------------------------------------------

impl Config {
    /// Parse and validate configuration from a JSON string.
    ///
    /// All invariants are checked at parse time:
    /// - Tenant IDs are alphanumeric with hyphens and dots
    /// - No tenant is named `"default"`
    /// - Every tenant has a non-empty `browser_cmd`
    /// - Every rule's `tenant` references an existing tenant key
    /// - Every rule's `pattern` is a valid regex
    /// - `defaults.unmatched` is `"local"` or references an existing tenant
    /// - `enabled` fields are resolved to concrete bools (default `true`)
    pub fn from_json(content: &str) -> Result<Self, ConfigError> {
        let raw: ConfigRaw = serde_json::from_str(content)?;

        // Validate tenant IDs and build tenant map
        let mut tenants = HashMap::with_capacity(raw.tenants.len());
        for (key, tenant_raw) in raw.tenants {
            let tid = TenantId::from(key.clone());
            if !tid.is_valid() {
                return Err(ConfigError::InvalidTenantId(key));
            }
            if tid.is_default() {
                return Err(ConfigError::ReservedTenantId(key));
            }
            if tenant_raw.browser_cmd.is_empty() {
                return Err(ConfigError::EmptyBrowserCmd(key));
            }
            tenants.insert(
                tid,
                Tenant {
                    browser_cmd: tenant_raw.browser_cmd,
                    badge_label: tenant_raw.badge_label,
                    badge_color: tenant_raw.badge_color,
                },
            );
        }

        // Validate and compile rules
        let mut rules = Vec::with_capacity(raw.rules.len());
        for (index, rule_raw) in raw.rules.into_iter().enumerate() {
            let tenant = TenantId::from(rule_raw.tenant.clone());
            if !tenants.contains_key(&tenant) {
                return Err(ConfigError::UnknownRuleTenant {
                    index,
                    tenant: rule_raw.tenant,
                });
            }
            let compiled = Regex::new(&rule_raw.pattern)
                .map_err(|source| ConfigError::InvalidPattern { index, source })?;
            rules.push(Rule {
                pattern: rule_raw.pattern,
                compiled,
                tenant,
                enabled: rule_raw.enabled.unwrap_or(true),
            });
        }

        // Validate defaults
        let unmatched = TenantId::from(raw.defaults.unmatched.clone());
        if !unmatched.is_local() && !tenants.contains_key(&unmatched) {
            return Err(ConfigError::InvalidUnmatchedTenant(raw.defaults.unmatched));
        }

        let defaults = Defaults {
            unmatched,
            notifications: raw.defaults.notifications,
            notification_timeout_ms: raw.defaults.notification_timeout_ms,
            cooldown_secs: raw.defaults.cooldown_secs,
            browser_launch_timeout_secs: raw.defaults.browser_launch_timeout_secs,
        };

        Ok(Config {
            socket: raw.socket,
            tenants,
            rules,
            defaults,
        })
    }

    /// Parse a single rule from JSON, validating against existing tenants.
    pub fn parse_rule(
        json: &str,
        tenants: &HashMap<TenantId, Tenant>,
    ) -> Result<Rule, ConfigError> {
        let raw: RuleRaw = serde_json::from_str(json)?;
        let tenant = TenantId::from(raw.tenant.clone());
        if !tenants.contains_key(&tenant) {
            return Err(ConfigError::UnknownRuleTenant {
                index: 0,
                tenant: raw.tenant,
            });
        }
        let compiled = Regex::new(&raw.pattern)
            .map_err(|source| ConfigError::InvalidPattern { index: 0, source })?;
        Ok(Rule {
            pattern: raw.pattern,
            compiled,
            tenant,
            enabled: raw.enabled.unwrap_or(true),
        })
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_config_json() -> &'static str {
        r##"{
            "socket": "/run/url-router/url-router.sock",
            "tenants": {
                "mydesktop": {
                    "browser_cmd": "xdg-open",
                    "badge_label": "P",
                    "badge_color": "#4285f4"
                },
                "work-container": {
                    "browser_cmd": "machinectl shell work -- chromium",
                    "badge_label": "W",
                    "badge_color": "#34a853"
                }
            },
            "rules": [
                {
                    "pattern": ".*\\.example\\.com",
                    "tenant": "work-container",
                    "enabled": true
                },
                {
                    "pattern": ".*\\.personal\\.io",
                    "tenant": "mydesktop"
                }
            ],
            "defaults": {
                "unmatched": "local",
                "notifications": true,
                "notification_timeout_ms": 3000,
                "cooldown_secs": 5,
                "browser_launch_timeout_secs": 15
            }
        }"##
    }

    #[test]
    fn parse_valid_config() {
        let config = Config::from_json(sample_config_json()).unwrap();
        assert_eq!(config.socket, "/run/url-router/url-router.sock");
        assert_eq!(config.tenants.len(), 2);
        assert_eq!(config.rules.len(), 2);
        assert!(config.defaults.unmatched.is_local());
        assert!(config.defaults.notifications);
    }

    #[test]
    fn enabled_defaults_to_true() {
        let config = Config::from_json(sample_config_json()).unwrap();
        // Second rule has no explicit enabled field
        assert!(config.rules[1].enabled);
    }

    #[test]
    fn default_socket_path_applied() {
        let json = r#"{"tenants": {}, "rules": []}"#;
        let config = Config::from_json(json).unwrap();
        assert_eq!(config.socket, DEFAULT_SOCKET_PATH);
    }

    #[test]
    fn reject_default_tenant_key() {
        let json = r#"{
            "tenants": { "default": { "browser_cmd": "firefox" } },
            "rules": []
        }"#;
        let err = Config::from_json(json).unwrap_err();
        assert!(matches!(err, ConfigError::ReservedTenantId(_)));
    }

    #[test]
    fn reject_empty_browser_cmd() {
        let json = r#"{
            "tenants": { "host": { "browser_cmd": "" } },
            "rules": []
        }"#;
        let err = Config::from_json(json).unwrap_err();
        assert!(matches!(err, ConfigError::EmptyBrowserCmd(_)));
    }

    #[test]
    fn reject_unknown_rule_tenant() {
        let json = r#"{
            "tenants": { "host": { "browser_cmd": "firefox" } },
            "rules": [{ "pattern": ".*", "tenant": "unknown" }]
        }"#;
        let err = Config::from_json(json).unwrap_err();
        assert!(matches!(err, ConfigError::UnknownRuleTenant { .. }));
    }

    #[test]
    fn reject_invalid_regex() {
        let json = r#"{
            "tenants": { "host": { "browser_cmd": "firefox" } },
            "rules": [{ "pattern": "[invalid", "tenant": "host" }]
        }"#;
        let err = Config::from_json(json).unwrap_err();
        assert!(matches!(err, ConfigError::InvalidPattern { .. }));
    }

    #[test]
    fn reject_invalid_unmatched_tenant() {
        let json = r#"{
            "tenants": { "host": { "browser_cmd": "firefox" } },
            "rules": [],
            "defaults": { "unmatched": "nonexistent" }
        }"#;
        let err = Config::from_json(json).unwrap_err();
        assert!(matches!(err, ConfigError::InvalidUnmatchedTenant(_)));
    }

    #[test]
    fn config_serializes_to_json() {
        let config = Config::from_json(sample_config_json()).unwrap();
        let json = serde_json::to_string(&config).unwrap();
        assert!(json.contains("mydesktop"));
        assert!(json.contains("work-container"));
    }

    #[test]
    fn parse_single_rule() {
        let config = Config::from_json(sample_config_json()).unwrap();
        let rule_json = r#"{"pattern": ".*\\.test\\.com", "tenant": "mydesktop"}"#;
        let rule = Config::parse_rule(rule_json, &config.tenants).unwrap();
        assert_eq!(rule.tenant.as_str(), "mydesktop");
        assert!(rule.enabled);
    }

    #[test]
    fn rule_matching() {
        let config = Config::from_json(sample_config_json()).unwrap();
        assert!(config.rules[0].is_match("https://foo.example.com/path"));
        assert!(!config.rules[0].is_match("https://other.com"));
    }

    #[test]
    fn reject_invalid_tenant_id_characters() {
        let json = r#"{
            "tenants": { "bad tenant": { "browser_cmd": "firefox" } },
            "rules": []
        }"#;
        let err = Config::from_json(json).unwrap_err();
        assert!(matches!(err, ConfigError::InvalidTenantId(_)));
    }

    #[test]
    fn empty_config() {
        let json = "{}";
        let config = Config::from_json(json).unwrap();
        assert!(config.tenants.is_empty());
        assert!(config.rules.is_empty());
        assert!(config.defaults.unmatched.is_local());
    }
}
