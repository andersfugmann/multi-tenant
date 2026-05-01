//! Protocol command and response types for the url-router line-based protocol.
//!
//! Provides `Command` and `Response` enums with `FromStr`/`Display` impls
//! for parsing and formatting line-based protocol messages. Also provides
//! serde types for embedded JSON payloads (add-rule, get-config, status).
//!
//! This module handles the text protocol only — no I/O.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

use crate::config::RuleDefinition;
use crate::types::{RuleIndex, TenantId};

/// A command sent from a client to the daemon (one line of text).
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// Evaluate rules. Respond LOCAL/REMOTE. Never launches the local browser.
    Open { url: String },
    /// Evaluate rules (or target specific tenant) and launch the browser.
    /// The special tenant "default" means evaluate rules.
    OpenOn { tenant: TenantId, url: String },
    /// Launch the local browser immediately. Internal: peer daemon forwarding.
    OpenLocal { url: String },
    /// Dry-run: evaluate rules, report match. No side effects.
    Test { url: String },
    /// Append a routing rule to the config file.
    AddRule { rule: RuleDefinition },
    /// Replace a routing rule at a given index.
    UpdateRule {
        index: RuleIndex,
        rule: RuleDefinition,
    },
    /// Delete a routing rule at a given index.
    DeleteRule { index: RuleIndex },
    /// Replace the entire configuration.
    SetConfig { json: String },
    /// Return the current configuration.
    GetConfig,
    /// Return daemon health information.
    Status,
}

/// A response sent from the daemon to a client (one line of text).
#[derive(Debug, Clone, PartialEq)]
pub enum Response {
    /// URL belongs to this tenant; caller should allow navigation.
    Local,
    /// Forwarded to remote tenant; caller should close/go-back the tab.
    Remote { tenant: TenantId },
    /// Remote tenant unreachable; caller should allow navigation (local fallback).
    Fallback,
    /// Operation succeeded, URL opened in local browser.
    OkLocal,
    /// Operation succeeded, forwarded to remote tenant.
    OkForwarded { tenant: TenantId },
    /// Operation succeeded with fallback (remote unreachable, opened locally).
    OkFallback,
    /// Generic OK (for open-local, add-rule).
    Ok,
    /// Rule matched at given index.
    Match {
        tenant: TenantId,
        rule_index: RuleIndex,
    },
    /// No rule matched; shows default action.
    NoMatch { default_action: String },
    /// Full config as JSON.
    Config { json: String },
    /// Daemon status as JSON.
    Status { json: String },
    /// Unknown tenant ID.
    ErrorUnknownTenant { tenant: TenantId },
    /// Generic error.
    Error { message: String },
}

/// Error type for protocol parsing failures.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum ParseError {
    #[error("empty command")]
    EmptyCommand,
    #[error("unknown command: {0}")]
    UnknownCommand(String),
    #[error("missing argument for {command}: expected {expected}")]
    MissingArgument { command: String, expected: String },
    #[error("invalid JSON in add-rule: {0}")]
    InvalidJson(String),
    #[error("invalid rule index: {0}")]
    InvalidIndex(String),
    #[error("unknown response: {0}")]
    UnknownResponse(String),
    #[error("URL contains invalid characters (newline)")]
    InvalidUrl,
}

/// Validate that a URL is safe for the line-based protocol (no newlines).
fn validate_url(url: &str) -> Result<(), ParseError> {
    if url.contains('\n') || url.contains('\r') {
        return Err(ParseError::InvalidUrl);
    }
    Ok(())
}

impl FromStr for Command {
    type Err = ParseError;

    fn from_str(line: &str) -> Result<Self, Self::Err> {
        let line = line.trim();
        if line.is_empty() {
            return Err(ParseError::EmptyCommand);
        }

        let (cmd, rest) = split_first_word(line);

        match cmd {
            "open" => {
                let url = rest.ok_or(ParseError::MissingArgument {
                    command: "open".into(),
                    expected: "url".into(),
                })?;
                validate_url(url)?;
                Ok(Command::Open { url: url.into() })
            }
            "open-on" => {
                let args = rest.ok_or(ParseError::MissingArgument {
                    command: "open-on".into(),
                    expected: "tenant-id url".into(),
                })?;
                let (tenant_str, url) = split_first_word(args);
                let url = url.ok_or(ParseError::MissingArgument {
                    command: "open-on".into(),
                    expected: "url (after tenant-id)".into(),
                })?;
                validate_url(url)?;
                Ok(Command::OpenOn {
                    tenant: TenantId::new(tenant_str),
                    url: url.into(),
                })
            }
            "open-local" => {
                let url = rest.ok_or(ParseError::MissingArgument {
                    command: "open-local".into(),
                    expected: "url".into(),
                })?;
                validate_url(url)?;
                Ok(Command::OpenLocal { url: url.into() })
            }
            "test" => {
                let url = rest.ok_or(ParseError::MissingArgument {
                    command: "test".into(),
                    expected: "url".into(),
                })?;
                validate_url(url)?;
                Ok(Command::Test { url: url.into() })
            }
            "add-rule" => {
                let json = rest.ok_or(ParseError::MissingArgument {
                    command: "add-rule".into(),
                    expected: "json".into(),
                })?;
                let rule: RuleDefinition = serde_json::from_str(json)
                    .map_err(|e| ParseError::InvalidJson(e.to_string()))?;
                Ok(Command::AddRule { rule })
            }
            "update-rule" => {
                let args = rest.ok_or(ParseError::MissingArgument {
                    command: "update-rule".into(),
                    expected: "index json".into(),
                })?;
                let (index_str, json) = split_first_word(args);
                let index: usize = index_str
                    .parse()
                    .map_err(|_| ParseError::InvalidIndex(index_str.into()))?;
                let json = json.ok_or(ParseError::MissingArgument {
                    command: "update-rule".into(),
                    expected: "json (after index)".into(),
                })?;
                let rule: RuleDefinition = serde_json::from_str(json)
                    .map_err(|e| ParseError::InvalidJson(e.to_string()))?;
                Ok(Command::UpdateRule {
                    index: RuleIndex(index),
                    rule,
                })
            }
            "delete-rule" => {
                let index_str = rest.ok_or(ParseError::MissingArgument {
                    command: "delete-rule".into(),
                    expected: "index".into(),
                })?;
                let index: usize = index_str
                    .trim()
                    .parse()
                    .map_err(|_| ParseError::InvalidIndex(index_str.into()))?;
                Ok(Command::DeleteRule {
                    index: RuleIndex(index),
                })
            }
            "get-config" => Ok(Command::GetConfig),
            "set-config" => {
                let json = rest.ok_or(ParseError::MissingArgument {
                    command: "set-config".into(),
                    expected: "json".into(),
                })?;
                // Validate it parses as a Config
                let _: crate::config::Config = serde_json::from_str(json)
                    .map_err(|e| ParseError::InvalidJson(e.to_string()))?;
                Ok(Command::SetConfig { json: json.into() })
            }
            "status" => Ok(Command::Status),
            other => Err(ParseError::UnknownCommand(other.into())),
        }
    }
}

impl fmt::Display for Command {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Command::Open { url } => write!(f, "open {url}"),
            Command::OpenOn { tenant, url } => write!(f, "open-on {tenant} {url}"),
            Command::OpenLocal { url } => write!(f, "open-local {url}"),
            Command::Test { url } => write!(f, "test {url}"),
            Command::AddRule { rule } => {
                let json = serde_json::to_string(rule).expect("rule serialization cannot fail");
                write!(f, "add-rule {json}")
            }
            Command::UpdateRule { index, rule } => {
                let json = serde_json::to_string(rule).expect("rule serialization cannot fail");
                write!(f, "update-rule {index} {json}")
            }
            Command::DeleteRule { index } => write!(f, "delete-rule {index}"),
            Command::SetConfig { json } => write!(f, "set-config {json}"),
            Command::GetConfig => write!(f, "get-config"),
            Command::Status => write!(f, "status"),
        }
    }
}

impl FromStr for Response {
    type Err = ParseError;

    fn from_str(line: &str) -> Result<Self, Self::Err> {
        let line = line.trim();
        if line.is_empty() {
            return Err(ParseError::UnknownResponse("(empty)".into()));
        }

        // Try exact matches first
        match line {
            "LOCAL" => return Ok(Response::Local),
            "FALLBACK" => return Ok(Response::Fallback),
            "OK local" => return Ok(Response::OkLocal),
            "OK fallback" => return Ok(Response::OkFallback),
            "OK" => return Ok(Response::Ok),
            _ => {}
        }

        let (first, rest) = split_first_word(line);

        match first {
            "REMOTE" => {
                let tenant = rest.ok_or(ParseError::MissingArgument {
                    command: "REMOTE".into(),
                    expected: "tenant-id".into(),
                })?;
                Ok(Response::Remote {
                    tenant: TenantId::new(tenant),
                })
            }
            "OK" => {
                // "OK forwarded <tenant>"
                let rest = rest.unwrap_or("");
                let (sub, tenant_str) = split_first_word(rest);
                if sub == "forwarded" {
                    let tenant = tenant_str.ok_or(ParseError::MissingArgument {
                        command: "OK forwarded".into(),
                        expected: "tenant-id".into(),
                    })?;
                    Ok(Response::OkForwarded {
                        tenant: TenantId::new(tenant),
                    })
                } else {
                    Err(ParseError::UnknownResponse(line.into()))
                }
            }
            "MATCH" => {
                let rest = rest.ok_or(ParseError::MissingArgument {
                    command: "MATCH".into(),
                    expected: "tenant-id rule-index".into(),
                })?;
                let (tenant_str, index_str) = split_first_word(rest);
                let index_str = index_str.ok_or(ParseError::MissingArgument {
                    command: "MATCH".into(),
                    expected: "rule-index".into(),
                })?;
                let index: usize = index_str
                    .parse()
                    .map_err(|_| ParseError::UnknownResponse(line.into()))?;
                Ok(Response::Match {
                    tenant: TenantId::new(tenant_str),
                    rule_index: RuleIndex(index),
                })
            }
            "NOMATCH" => {
                let default = rest.ok_or(ParseError::MissingArgument {
                    command: "NOMATCH".into(),
                    expected: "default-action".into(),
                })?;
                Ok(Response::NoMatch {
                    default_action: default.into(),
                })
            }
            "CONFIG" => {
                let json = rest.ok_or(ParseError::MissingArgument {
                    command: "CONFIG".into(),
                    expected: "json".into(),
                })?;
                Ok(Response::Config { json: json.into() })
            }
            "STATUS" => {
                let json = rest.ok_or(ParseError::MissingArgument {
                    command: "STATUS".into(),
                    expected: "json".into(),
                })?;
                Ok(Response::Status { json: json.into() })
            }
            "ERR" => {
                let rest = rest.unwrap_or("");
                let (sub, tenant_str) = split_first_word(rest);
                if sub == "unknown-tenant" {
                    let tenant = tenant_str.ok_or(ParseError::MissingArgument {
                        command: "ERR unknown-tenant".into(),
                        expected: "tenant-id".into(),
                    })?;
                    Ok(Response::ErrorUnknownTenant {
                        tenant: TenantId::new(tenant),
                    })
                } else {
                    Ok(Response::Error {
                        message: rest.into(),
                    })
                }
            }
            _ => Err(ParseError::UnknownResponse(line.into())),
        }
    }
}

impl fmt::Display for Response {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Response::Local => write!(f, "LOCAL"),
            Response::Remote { tenant } => write!(f, "REMOTE {tenant}"),
            Response::Fallback => write!(f, "FALLBACK"),
            Response::OkLocal => write!(f, "OK local"),
            Response::OkForwarded { tenant } => write!(f, "OK forwarded {tenant}"),
            Response::OkFallback => write!(f, "OK fallback"),
            Response::Ok => write!(f, "OK"),
            Response::Match { tenant, rule_index } => write!(f, "MATCH {tenant} {rule_index}"),
            Response::NoMatch { default_action } => write!(f, "NOMATCH {default_action}"),
            Response::Config { json } => write!(f, "CONFIG {json}"),
            Response::Status { json } => write!(f, "STATUS {json}"),
            Response::ErrorUnknownTenant { tenant } => write!(f, "ERR unknown-tenant {tenant}"),
            Response::Error { message } => write!(f, "ERR {message}"),
        }
    }
}

/// Split a string into the first whitespace-delimited word and the rest.
fn split_first_word(s: &str) -> (&str, Option<&str>) {
    match s.find(char::is_whitespace) {
        Some(pos) => (&s[..pos], Some(s[pos + 1..].trim_start())),
        None => (s, None),
    }
}

/// JSON payload for the `status` response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StatusInfo {
    pub tenant: TenantId,
    pub uptime_secs: u64,
    pub config_path: String,
    pub rule_count: usize,
    pub peers: std::collections::HashMap<String, String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_open_command() {
        let cmd: Command = "open https://github.com/org/repo".parse().unwrap();
        assert_eq!(
            cmd,
            Command::Open {
                url: "https://github.com/org/repo".into()
            }
        );
    }

    #[test]
    fn parse_open_on_command() {
        let cmd: Command = "open-on work https://example.com".parse().unwrap();
        assert_eq!(
            cmd,
            Command::OpenOn {
                tenant: TenantId::new("work"),
                url: "https://example.com".into()
            }
        );
    }

    #[test]
    fn parse_open_on_default() {
        let cmd: Command = "open-on default https://example.com".parse().unwrap();
        if let Command::OpenOn { tenant, .. } = &cmd {
            assert!(tenant.is_default());
        } else {
            panic!("expected OpenOn");
        }
    }

    #[test]
    fn parse_open_local_command() {
        let cmd: Command = "open-local https://example.com".parse().unwrap();
        assert_eq!(
            cmd,
            Command::OpenLocal {
                url: "https://example.com".into()
            }
        );
    }

    #[test]
    fn parse_test_command() {
        let cmd: Command = "test https://example.com".parse().unwrap();
        assert_eq!(
            cmd,
            Command::Test {
                url: "https://example.com".into()
            }
        );
    }

    #[test]
    fn parse_add_rule_command() {
        let cmd: Command = r#"add-rule {"pattern":"^https://example\\.com","tenant":"work"}"#
            .parse()
            .unwrap();
        if let Command::AddRule { rule } = cmd {
            assert_eq!(rule.tenant, TenantId::new("work"));
        } else {
            panic!("expected AddRule");
        }
    }

    #[test]
    fn parse_get_config_command() {
        let cmd: Command = "get-config".parse().unwrap();
        assert_eq!(cmd, Command::GetConfig);
    }

    #[test]
    fn parse_status_command() {
        let cmd: Command = "status".parse().unwrap();
        assert_eq!(cmd, Command::Status);
    }

    #[test]
    fn parse_empty_command_is_error() {
        let result: Result<Command, _> = "".parse();
        assert!(result.is_err());
    }

    #[test]
    fn parse_unknown_command_is_error() {
        let result: Result<Command, _> = "foobar".parse();
        assert!(matches!(result, Err(ParseError::UnknownCommand(_))));
    }

    #[test]
    fn command_roundtrip() {
        let commands = vec![
            "open https://github.com",
            "open-on work https://example.com",
            "open-on default https://example.com",
            "open-local https://example.com",
            "test https://example.com",
            "get-config",
            "status",
        ];
        for input in commands {
            let cmd: Command = input.parse().unwrap();
            let output = cmd.to_string();
            let reparsed: Command = output.parse().unwrap();
            assert_eq!(cmd, reparsed, "roundtrip failed for: {input}");
        }
    }

    #[test]
    fn parse_local_response() {
        let resp: Response = "LOCAL".parse().unwrap();
        assert_eq!(resp, Response::Local);
    }

    #[test]
    fn parse_remote_response() {
        let resp: Response = "REMOTE work".parse().unwrap();
        assert_eq!(
            resp,
            Response::Remote {
                tenant: TenantId::new("work")
            }
        );
    }

    #[test]
    fn parse_fallback_response() {
        let resp: Response = "FALLBACK".parse().unwrap();
        assert_eq!(resp, Response::Fallback);
    }

    #[test]
    fn parse_ok_local_response() {
        let resp: Response = "OK local".parse().unwrap();
        assert_eq!(resp, Response::OkLocal);
    }

    #[test]
    fn parse_ok_forwarded_response() {
        let resp: Response = "OK forwarded work".parse().unwrap();
        assert_eq!(
            resp,
            Response::OkForwarded {
                tenant: TenantId::new("work")
            }
        );
    }

    #[test]
    fn parse_ok_response() {
        let resp: Response = "OK".parse().unwrap();
        assert_eq!(resp, Response::Ok);
    }

    #[test]
    fn parse_match_response() {
        let resp: Response = "MATCH work 1".parse().unwrap();
        assert_eq!(
            resp,
            Response::Match {
                tenant: TenantId::new("work"),
                rule_index: RuleIndex(1),
            }
        );
    }

    #[test]
    fn parse_nomatch_response() {
        let resp: Response = "NOMATCH local".parse().unwrap();
        assert_eq!(
            resp,
            Response::NoMatch {
                default_action: "local".into()
            }
        );
    }

    #[test]
    fn parse_err_unknown_tenant_response() {
        let resp: Response = "ERR unknown-tenant foobar".parse().unwrap();
        assert_eq!(
            resp,
            Response::ErrorUnknownTenant {
                tenant: TenantId::new("foobar")
            }
        );
    }

    #[test]
    fn parse_err_response() {
        let resp: Response = "ERR browser launch failed".parse().unwrap();
        assert_eq!(
            resp,
            Response::Error {
                message: "browser launch failed".into()
            }
        );
    }

    #[test]
    fn response_roundtrip() {
        let responses = vec![
            Response::Local,
            Response::Remote {
                tenant: TenantId::new("work"),
            },
            Response::Fallback,
            Response::OkLocal,
            Response::OkForwarded {
                tenant: TenantId::new("host"),
            },
            Response::OkFallback,
            Response::Ok,
            Response::Match {
                tenant: TenantId::new("work"),
                rule_index: RuleIndex(3),
            },
            Response::NoMatch {
                default_action: "local".into(),
            },
            Response::ErrorUnknownTenant {
                tenant: TenantId::new("bad"),
            },
            Response::Error {
                message: "something went wrong".into(),
            },
        ];
        for resp in responses {
            let line = resp.to_string();
            let reparsed: Response = line.parse().unwrap();
            assert_eq!(resp, reparsed, "roundtrip failed for: {line}");
        }
    }
}
