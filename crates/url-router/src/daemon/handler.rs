//! Command handler — pure logic for processing protocol commands.
//!
//! Takes a parsed `Command` and config, returns a `Response`.
//! No I/O — side-effectful operations (browser launch, forwarding)
//! are returned as `Action` values for the caller to execute.

use url_router_protocol::config::Config;
use url_router_protocol::matching::{match_url, MatchResult};
use url_router_protocol::protocol::{Command, Response};
use url_router_protocol::types::TenantId;

/// An action the daemon should perform after handling a command.
/// Separates the routing decision (pure) from the side effects (I/O).
#[derive(Debug, PartialEq)]
pub enum Action {
    /// Send the response to the client. No further action needed.
    Respond(Response),
    /// Open URL in the local browser, then respond.
    OpenLocalBrowser { url: String, response: Response },
    /// Forward URL to a peer daemon's socket, then respond.
    ForwardToPeer {
        tenant: TenantId,
        url: String,
        /// Response to send if forwarding succeeds.
        on_success: Response,
        /// Response to send if forwarding fails (fallback).
        on_failure: Response,
    },
}

/// Handle a parsed command, returning the action(s) the daemon should take.
pub fn handle_command(cmd: Command, config: &Config, local_tenant: &TenantId) -> Action {
    match cmd {
        Command::Open { url } => handle_open(&url, config, local_tenant),
        Command::OpenOn { tenant, url } => handle_open_on(tenant, &url, config, local_tenant),
        Command::OpenLocal { url } => Action::OpenLocalBrowser {
            url,
            response: Response::Ok,
        },
        Command::Test { url } => {
            let result = match_url(&url, config);
            let response = match result {
                MatchResult::Matched { tenant, rule_index } => {
                    Response::Match { tenant, rule_index }
                }
                MatchResult::Unmatched { default_action } => Response::NoMatch { default_action },
            };
            Action::Respond(response)
        }
        Command::AddRule { rule } => {
            // Validation: check that the tenant exists in config
            if config.tenant(rule.tenant.as_str()).is_none() {
                return Action::Respond(Response::ErrorUnknownTenant {
                    tenant: rule.tenant,
                });
            }
            // Validate regex compiles
            if let Err(e) = regex::Regex::new(&rule.pattern) {
                return Action::Respond(Response::Error {
                    message: format!("invalid regex: {e}"),
                });
            }
            // The actual file write is handled by the caller (I/O boundary)
            // For now, return Ok — the server will handle the config mutation
            Action::Respond(Response::Ok)
        }
        Command::GetConfig => {
            let json = config
                .to_json()
                .unwrap_or_else(|e| format!("{{\"error\": \"{e}\"}}"));
            Action::Respond(Response::Config { json })
        }
        Command::Status => {
            // Status info is populated by the server with runtime data
            Action::Respond(Response::Error {
                message: "status handled by server".into(),
            })
        }
    }
}

/// Handle `open <url>` — evaluate rules, respond LOCAL/REMOTE.
fn handle_open(url: &str, config: &Config, local_tenant: &TenantId) -> Action {
    let result = match_url(url, config);

    match result {
        MatchResult::Matched { tenant, .. } => {
            if &tenant == local_tenant {
                Action::Respond(Response::Local)
            } else {
                Action::ForwardToPeer {
                    tenant: tenant.clone(),
                    url: url.to_string(),
                    on_success: Response::Remote { tenant },
                    on_failure: Response::Fallback,
                }
            }
        }
        MatchResult::Unmatched { default_action } => {
            if default_action == "local" {
                Action::Respond(Response::Local)
            } else {
                // Default action is a tenant ID
                let target = TenantId::new(&default_action);
                if target == *local_tenant {
                    Action::Respond(Response::Local)
                } else {
                    Action::ForwardToPeer {
                        tenant: target.clone(),
                        url: url.to_string(),
                        on_success: Response::Remote { tenant: target },
                        on_failure: Response::Fallback,
                    }
                }
            }
        }
    }
}

/// Handle `open-on <tenant> <url>` — explicit routing or rule-evaluated.
fn handle_open_on(tenant: TenantId, url: &str, config: &Config, local_tenant: &TenantId) -> Action {
    if tenant.is_default() {
        // "default" means evaluate rules and launch browser
        return handle_open_on_default(url, config, local_tenant);
    }

    // Check tenant exists
    if config.tenant(tenant.as_str()).is_none() {
        return Action::Respond(Response::ErrorUnknownTenant { tenant });
    }

    if tenant == *local_tenant {
        // Targeting self — open locally
        Action::OpenLocalBrowser {
            url: url.to_string(),
            response: Response::OkLocal,
        }
    } else {
        // Forward to peer
        Action::ForwardToPeer {
            tenant: tenant.clone(),
            url: url.to_string(),
            on_success: Response::OkForwarded { tenant },
            on_failure: Response::OkFallback,
        }
    }
}

/// Handle `open-on default <url>` — evaluate rules and launch browser.
fn handle_open_on_default(url: &str, config: &Config, local_tenant: &TenantId) -> Action {
    let result = match_url(url, config);

    match result {
        MatchResult::Matched { tenant, .. } => {
            if &tenant == local_tenant {
                Action::OpenLocalBrowser {
                    url: url.to_string(),
                    response: Response::OkLocal,
                }
            } else {
                Action::ForwardToPeer {
                    tenant: tenant.clone(),
                    url: url.to_string(),
                    on_success: Response::OkForwarded { tenant },
                    on_failure: Response::OkFallback,
                }
            }
        }
        MatchResult::Unmatched { default_action } => {
            if default_action == "local" {
                Action::OpenLocalBrowser {
                    url: url.to_string(),
                    response: Response::OkLocal,
                }
            } else {
                let target = TenantId::new(&default_action);
                if target == *local_tenant {
                    Action::OpenLocalBrowser {
                        url: url.to_string(),
                        response: Response::OkLocal,
                    }
                } else {
                    Action::ForwardToPeer {
                        tenant: target.clone(),
                        url: url.to_string(),
                        on_success: Response::OkForwarded { tenant: target },
                        on_failure: Response::OkFallback,
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use url_router_protocol::types::RuleIndex;

    fn test_config() -> Config {
        Config::from_json(
            r#"{
            "tenants": {
                "host": { "name": "Personal", "browser_cmd": "edge", "socket": "/run/url-router/host.sock" },
                "work": { "name": "Work", "browser_cmd": "chromium", "socket": "/run/url-router/work.sock" }
            },
            "rules": [
                { "pattern": "^https?://(www\\.)?github\\.com(/|$)", "tenant": "host" },
                { "pattern": "^https?://.*\\.office\\.com(/|$)", "tenant": "work" }
            ],
            "defaults": { "unmatched": "local" }
        }"#,
        )
        .unwrap()
    }

    #[test]
    fn open_local_url_returns_local() {
        let config = test_config();
        let action = handle_command(
            Command::Open {
                url: "https://github.com/org/repo".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert_eq!(action, Action::Respond(Response::Local));
    }

    #[test]
    fn open_remote_url_forwards() {
        let config = test_config();
        let action = handle_command(
            Command::Open {
                url: "https://outlook.office.com/mail".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert!(matches!(action, Action::ForwardToPeer { .. }));
        if let Action::ForwardToPeer { on_success, .. } = action {
            assert_eq!(
                on_success,
                Response::Remote {
                    tenant: TenantId::new("work")
                }
            );
        }
    }

    #[test]
    fn open_unmatched_url_returns_local_when_default_is_local() {
        let config = test_config();
        let action = handle_command(
            Command::Open {
                url: "https://example.org".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert_eq!(action, Action::Respond(Response::Local));
    }

    #[test]
    fn open_on_default_local_launches_browser() {
        let config = test_config();
        let action = handle_command(
            Command::OpenOn {
                tenant: TenantId::new("default"),
                url: "https://github.com/org".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert!(matches!(action, Action::OpenLocalBrowser { .. }));
    }

    #[test]
    fn open_on_default_remote_forwards() {
        let config = test_config();
        let action = handle_command(
            Command::OpenOn {
                tenant: TenantId::new("default"),
                url: "https://outlook.office.com/mail".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert!(matches!(action, Action::ForwardToPeer { .. }));
    }

    #[test]
    fn open_on_specific_tenant_forwards() {
        let config = test_config();
        let action = handle_command(
            Command::OpenOn {
                tenant: TenantId::new("work"),
                url: "https://example.com".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert!(matches!(action, Action::ForwardToPeer { .. }));
    }

    #[test]
    fn open_on_self_launches_browser() {
        let config = test_config();
        let action = handle_command(
            Command::OpenOn {
                tenant: TenantId::new("host"),
                url: "https://example.com".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert!(matches!(action, Action::OpenLocalBrowser { .. }));
    }

    #[test]
    fn open_on_unknown_tenant_errors() {
        let config = test_config();
        let action = handle_command(
            Command::OpenOn {
                tenant: TenantId::new("unknown"),
                url: "https://example.com".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert!(matches!(
            action,
            Action::Respond(Response::ErrorUnknownTenant { .. })
        ));
    }

    #[test]
    fn open_local_launches_browser() {
        let config = test_config();
        let action = handle_command(
            Command::OpenLocal {
                url: "https://example.com".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert!(matches!(action, Action::OpenLocalBrowser { .. }));
    }

    #[test]
    fn test_command_returns_match() {
        let config = test_config();
        let action = handle_command(
            Command::Test {
                url: "https://github.com/org".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert_eq!(
            action,
            Action::Respond(Response::Match {
                tenant: TenantId::new("host"),
                rule_index: RuleIndex(0),
            })
        );
    }

    #[test]
    fn test_command_returns_nomatch() {
        let config = test_config();
        let action = handle_command(
            Command::Test {
                url: "https://example.org".into(),
            },
            &config,
            &TenantId::new("host"),
        );
        assert_eq!(
            action,
            Action::Respond(Response::NoMatch {
                default_action: "local".into()
            })
        );
    }

    #[test]
    fn get_config_returns_json() {
        let config = test_config();
        let action = handle_command(Command::GetConfig, &config, &TenantId::new("host"));
        assert!(matches!(action, Action::Respond(Response::Config { .. })));
    }
}
