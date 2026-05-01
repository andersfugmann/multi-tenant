//! URL matching against routing rules.
//!
//! Pure functions that evaluate a URL against a list of regex rules.
//! No I/O, no side effects — takes data in, returns a result.

use regex::Regex;

use crate::config::{Config, Rule};
use crate::types::{RuleIndex, TenantId};

/// The result of matching a URL against the routing rules.
#[derive(Debug, Clone, PartialEq)]
pub enum MatchResult {
    /// A rule matched. Contains the target tenant and the rule index.
    Matched {
        tenant: TenantId,
        rule_index: RuleIndex,
    },
    /// No rule matched. Contains the default action from config.
    Unmatched { default_action: String },
}

/// Evaluate a URL against the config's routing rules.
///
/// Iterates over active (enabled) rules in order. Returns the first match,
/// or `Unmatched` with the default action if no rule matches.
pub fn match_url(url: &str, config: &Config) -> MatchResult {
    for (index, rule) in config.active_rules() {
        if rule_matches(rule, url) {
            return MatchResult::Matched {
                tenant: rule.tenant.clone(),
                rule_index: RuleIndex(index),
            };
        }
    }

    MatchResult::Unmatched {
        default_action: config.defaults.unmatched.clone(),
    }
}

/// Check whether a single rule's regex pattern matches the URL.
fn rule_matches(rule: &Rule, url: &str) -> bool {
    Regex::new(&rule.pattern)
        .map(|re| re.is_match(url))
        .unwrap_or(false)
}

/// Pre-compile all rule patterns and return errors for invalid ones.
/// Useful for config validation.
pub fn validate_patterns(config: &Config) -> Vec<(RuleIndex, String)> {
    config
        .rules
        .iter()
        .enumerate()
        .filter_map(|(i, rule)| {
            Regex::new(&rule.pattern)
                .err()
                .map(|e| (RuleIndex(i), e.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    fn test_config() -> Config {
        Config::from_json(
            r#"{
            "tenants": {
                "host": { "name": "Personal", "browser_cmd": "edge", "socket": "/run/url-router/host.sock" },
                "work": { "name": "Work", "browser_cmd": "chromium", "socket": "/run/url-router/work.sock" }
            },
            "rules": [
                { "pattern": "^https?://(www\\.)?github\\.com(/|$)", "tenant": "host" },
                { "pattern": "^https?://.*\\.office\\.com(/|$)", "tenant": "work" },
                { "pattern": "^https?://disabled\\.example\\.com", "tenant": "work", "enabled": false }
            ],
            "defaults": { "unmatched": "local" }
        }"#,
        )
        .unwrap()
    }

    #[test]
    fn matches_first_rule() {
        let config = test_config();
        let result = match_url("https://github.com/org/repo", &config);
        assert_eq!(
            result,
            MatchResult::Matched {
                tenant: TenantId::new("host"),
                rule_index: RuleIndex(0),
            }
        );
    }

    #[test]
    fn matches_second_rule() {
        let config = test_config();
        let result = match_url("https://outlook.office.com/mail", &config);
        assert_eq!(
            result,
            MatchResult::Matched {
                tenant: TenantId::new("work"),
                rule_index: RuleIndex(1),
            }
        );
    }

    #[test]
    fn skips_disabled_rules() {
        let config = test_config();
        let result = match_url("https://disabled.example.com/page", &config);
        assert_eq!(
            result,
            MatchResult::Unmatched {
                default_action: "local".into(),
            }
        );
    }

    #[test]
    fn unmatched_url_returns_default() {
        let config = test_config();
        let result = match_url("https://example.org", &config);
        assert_eq!(
            result,
            MatchResult::Unmatched {
                default_action: "local".into(),
            }
        );
    }

    #[test]
    fn first_match_wins() {
        let config = Config::from_json(
            r#"{
            "tenants": {
                "a": { "name": "A", "browser_cmd": "a", "socket": "a.sock" },
                "b": { "name": "B", "browser_cmd": "b", "socket": "b.sock" }
            },
            "rules": [
                { "pattern": "^https://example\\.com", "tenant": "a" },
                { "pattern": "^https://example\\.com", "tenant": "b" }
            ]
        }"#,
        )
        .unwrap();
        let result = match_url("https://example.com/page", &config);
        assert_eq!(
            result,
            MatchResult::Matched {
                tenant: TenantId::new("a"),
                rule_index: RuleIndex(0),
            }
        );
    }

    #[test]
    fn validate_patterns_catches_invalid_regex() {
        let config = Config::from_json(
            r#"{
            "tenants": {},
            "rules": [
                { "pattern": "^valid", "tenant": "a" },
                { "pattern": "[invalid", "tenant": "b" }
            ]
        }"#,
        )
        .unwrap();
        let errors = validate_patterns(&config);
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].0, RuleIndex(1));
    }

    #[test]
    fn www_prefix_matches_github() {
        let config = test_config();
        let result = match_url("https://www.github.com/org/repo", &config);
        assert_eq!(
            result,
            MatchResult::Matched {
                tenant: TenantId::new("host"),
                rule_index: RuleIndex(0),
            }
        );
    }
}
