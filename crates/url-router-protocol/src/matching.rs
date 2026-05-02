//! URL-to-tenant rule evaluation.
//!
//! Pure functions only. Takes a URL and rules, returns a match result.
//! No I/O, no side effects.

use crate::config::Rule;
use crate::types::{RuleIndex, TenantId};

/// Evaluate a URL against a list of rules, returning the first match.
///
/// Only considers enabled rules. Returns the matching tenant ID and rule
/// index, or `None` if no rule matches.
pub fn match_url(url: &str, rules: &[Rule]) -> Option<(TenantId, RuleIndex)> {
    rules
        .iter()
        .enumerate()
        .filter(|(_, rule)| rule.enabled)
        .find(|(_, rule)| rule.is_match(url))
        .map(|(index, rule)| (rule.tenant.clone(), RuleIndex::from(index)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    fn test_config() -> Config {
        Config::from_json(
            r#"{
                "tenants": {
                    "personal": { "browser_cmd": "firefox" },
                    "work": { "browser_cmd": "chromium" }
                },
                "rules": [
                    { "pattern": ".*\\.work\\.com", "tenant": "work" },
                    { "pattern": ".*\\.personal\\.io", "tenant": "personal" },
                    { "pattern": ".*\\.shared\\.org", "tenant": "work", "enabled": false }
                ]
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn matches_first_matching_rule() {
        let config = test_config();
        let result = match_url("https://app.work.com/dashboard", &config.rules);
        let (tenant, index) = result.unwrap();
        assert_eq!(tenant.as_str(), "work");
        assert_eq!(index.value(), 0);
    }

    #[test]
    fn matches_second_rule() {
        let config = test_config();
        let result = match_url("https://blog.personal.io/post", &config.rules);
        let (tenant, index) = result.unwrap();
        assert_eq!(tenant.as_str(), "personal");
        assert_eq!(index.value(), 1);
    }

    #[test]
    fn returns_none_when_no_match() {
        let config = test_config();
        let result = match_url("https://unknown.example.com", &config.rules);
        assert!(result.is_none());
    }

    #[test]
    fn skips_disabled_rules() {
        let config = test_config();
        let result = match_url("https://app.shared.org/page", &config.rules);
        assert!(result.is_none());
    }

    #[test]
    fn first_match_wins() {
        let config = Config::from_json(
            r#"{
                "tenants": {
                    "a": { "browser_cmd": "firefox" },
                    "b": { "browser_cmd": "chromium" }
                },
                "rules": [
                    { "pattern": ".*", "tenant": "a" },
                    { "pattern": ".*", "tenant": "b" }
                ]
            }"#,
        )
        .unwrap();
        let (tenant, index) = match_url("https://anything.com", &config.rules).unwrap();
        assert_eq!(tenant.as_str(), "a");
        assert_eq!(index.value(), 0);
    }

    #[test]
    fn empty_rules_returns_none() {
        let result = match_url("https://example.com", &[]);
        assert!(result.is_none());
    }
}
