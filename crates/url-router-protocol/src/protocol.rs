//! Protocol command and response types for the line-based socket protocol.
//!
//! Defines `Command`, `Response`, and `ServerPush` enums with `FromStr` and
//! `Display` implementations for wire format conversion. The protocol is
//! text-based (one message per line), with URLs parsed as rest-of-line and
//! JSON payloads embedded inline. This module performs no I/O.

use std::fmt;
use std::str::FromStr;

use thiserror::Error;

use crate::types::{RuleIndex, TenantId};

/// Errors that occur when parsing protocol messages.
#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("empty command")]
    EmptyCommand,

    #[error("unknown command: {0}")]
    UnknownCommand(String),

    #[error("missing argument for {command}: expected {expected}")]
    MissingArgument {
        command: &'static str,
        expected: &'static str,
    },

    #[error("invalid rule index: {0}")]
    InvalidRuleIndex(#[from] std::num::ParseIntError),

    #[error("unknown response: {0}")]
    UnknownResponse(String),
}

// ---------------------------------------------------------------------------
// Commands (client → daemon)
// ---------------------------------------------------------------------------

/// A command sent from a client to the daemon over the socket protocol.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// Register this connection as a listener for the given tenant.
    Register { tenant_id: TenantId },
    /// Open a URL from the given source tenant; daemon evaluates routing rules.
    Open { tenant_id: TenantId, url: String },
    /// Open a URL explicitly on the given target tenant (no rule evaluation).
    OpenOn { tenant_id: TenantId, url: String },
    /// Test a URL against routing rules without actually opening it.
    Test { url: String },
    /// Retrieve the current configuration as JSON.
    GetConfig,
    /// Replace the entire configuration with the given JSON.
    SetConfig { json: String },
    /// Add a new routing rule from JSON.
    AddRule { json: String },
    /// Update a rule at the given index with new JSON.
    UpdateRule { index: RuleIndex, json: String },
    /// Delete the rule at the given index.
    DeleteRule { index: RuleIndex },
    /// Request daemon status information.
    Status,
}

impl FromStr for Command {
    type Err = ProtocolError;

    fn from_str(line: &str) -> Result<Self, Self::Err> {
        let line = line.trim();
        if line.is_empty() {
            return Err(ProtocolError::EmptyCommand);
        }

        let (keyword, rest) = split_first_word(line);
        match keyword {
            "register" => {
                let tenant_id = require_arg(rest, "register", "tenant_id")?;
                Ok(Command::Register {
                    tenant_id: TenantId::from(tenant_id.to_string()),
                })
            }
            "open" => {
                let rest = require_arg(rest, "open", "tenant_id url")?;
                let (tenant_str, url) = split_first_word(rest);
                if url.is_empty() {
                    return Err(ProtocolError::MissingArgument {
                        command: "open",
                        expected: "url",
                    });
                }
                Ok(Command::Open {
                    tenant_id: TenantId::from(tenant_str.to_string()),
                    url: url.to_string(),
                })
            }
            "open-on" => {
                let rest = require_arg(rest, "open-on", "tenant_id url")?;
                let (tenant_str, url) = split_first_word(rest);
                if url.is_empty() {
                    return Err(ProtocolError::MissingArgument {
                        command: "open-on",
                        expected: "url",
                    });
                }
                Ok(Command::OpenOn {
                    tenant_id: TenantId::from(tenant_str.to_string()),
                    url: url.to_string(),
                })
            }
            "test" => {
                let url = require_arg(rest, "test", "url")?;
                Ok(Command::Test {
                    url: url.to_string(),
                })
            }
            "get-config" => Ok(Command::GetConfig),
            "set-config" => {
                let json = require_arg(rest, "set-config", "json")?;
                Ok(Command::SetConfig {
                    json: json.to_string(),
                })
            }
            "add-rule" => {
                let json = require_arg(rest, "add-rule", "json")?;
                Ok(Command::AddRule {
                    json: json.to_string(),
                })
            }
            "update-rule" => {
                let rest = require_arg(rest, "update-rule", "index json")?;
                let (index_str, json) = split_first_word(rest);
                if json.is_empty() {
                    return Err(ProtocolError::MissingArgument {
                        command: "update-rule",
                        expected: "json",
                    });
                }
                let index = RuleIndex::from(index_str.parse::<usize>()?);
                Ok(Command::UpdateRule {
                    index,
                    json: json.to_string(),
                })
            }
            "delete-rule" => {
                let index_str = require_arg(rest, "delete-rule", "index")?;
                let index = RuleIndex::from(index_str.parse::<usize>()?);
                Ok(Command::DeleteRule { index })
            }
            "status" => Ok(Command::Status),
            _ => Err(ProtocolError::UnknownCommand(keyword.to_string())),
        }
    }
}

impl fmt::Display for Command {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Command::Register { tenant_id } => write!(f, "register {tenant_id}"),
            Command::Open { tenant_id, url } => write!(f, "open {tenant_id} {url}"),
            Command::OpenOn { tenant_id, url } => write!(f, "open-on {tenant_id} {url}"),
            Command::Test { url } => write!(f, "test {url}"),
            Command::GetConfig => write!(f, "get-config"),
            Command::SetConfig { json } => write!(f, "set-config {json}"),
            Command::AddRule { json } => write!(f, "add-rule {json}"),
            Command::UpdateRule { index, json } => write!(f, "update-rule {index} {json}"),
            Command::DeleteRule { index } => write!(f, "delete-rule {index}"),
            Command::Status => write!(f, "status"),
        }
    }
}

// ---------------------------------------------------------------------------
// Responses (daemon → client)
// ---------------------------------------------------------------------------

/// A response sent from the daemon to the client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Response {
    /// Command succeeded.
    Ok,
    /// Command failed with an error message.
    Error { message: String },
    /// URL should be handled locally (no routing).
    Local,
    /// URL was routed to a remote tenant.
    Remote { tenant_id: TenantId },
    /// Test result: URL matched a rule.
    Match {
        tenant_id: TenantId,
        rule_index: RuleIndex,
    },
    /// Test result: no rule matched; showing default tenant.
    NoMatch { default_tenant: TenantId },
    /// Configuration data as JSON.
    Config { json: String },
    /// Status information as JSON.
    Status { json: String },
}

impl FromStr for Response {
    type Err = ProtocolError;

    fn from_str(line: &str) -> Result<Self, Self::Err> {
        let line = line.trim();
        if line.is_empty() {
            return Err(ProtocolError::UnknownResponse(String::new()));
        }

        let (keyword, rest) = split_first_word(line);
        match keyword {
            "OK" => Ok(Response::Ok),
            "ERR" => Ok(Response::Error {
                message: rest.to_string(),
            }),
            "LOCAL" => Ok(Response::Local),
            "REMOTE" => {
                let tenant = require_arg(rest, "REMOTE", "tenant_id")?;
                Ok(Response::Remote {
                    tenant_id: TenantId::from(tenant.to_string()),
                })
            }
            "MATCH" => {
                let rest = require_arg(rest, "MATCH", "tenant_id rule_index")?;
                let (tenant_str, index_str) = split_first_word(rest);
                if index_str.is_empty() {
                    return Err(ProtocolError::MissingArgument {
                        command: "MATCH",
                        expected: "rule_index",
                    });
                }
                let index = RuleIndex::from(index_str.parse::<usize>()?);
                Ok(Response::Match {
                    tenant_id: TenantId::from(tenant_str.to_string()),
                    rule_index: index,
                })
            }
            "NOMATCH" => {
                let tenant = require_arg(rest, "NOMATCH", "default_tenant")?;
                Ok(Response::NoMatch {
                    default_tenant: TenantId::from(tenant.to_string()),
                })
            }
            "CONFIG" => {
                let json = require_arg(rest, "CONFIG", "json")?;
                Ok(Response::Config {
                    json: json.to_string(),
                })
            }
            "STATUS" => {
                let json = require_arg(rest, "STATUS", "json")?;
                Ok(Response::Status {
                    json: json.to_string(),
                })
            }
            _ => Err(ProtocolError::UnknownResponse(line.to_string())),
        }
    }
}

impl fmt::Display for Response {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Response::Ok => write!(f, "OK"),
            Response::Error { message } => write!(f, "ERR {message}"),
            Response::Local => write!(f, "LOCAL"),
            Response::Remote { tenant_id } => write!(f, "REMOTE {tenant_id}"),
            Response::Match {
                tenant_id,
                rule_index,
            } => write!(f, "MATCH {tenant_id} {rule_index}"),
            Response::NoMatch { default_tenant } => write!(f, "NOMATCH {default_tenant}"),
            Response::Config { json } => write!(f, "CONFIG {json}"),
            Response::Status { json } => write!(f, "STATUS {json}"),
        }
    }
}

// ---------------------------------------------------------------------------
// Server push (daemon → registered client)
// ---------------------------------------------------------------------------

/// A push message from the daemon to a registered listener.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerPush {
    /// Instruct the client's browser to navigate to this URL.
    Navigate { url: String },
}

impl FromStr for ServerPush {
    type Err = ProtocolError;

    fn from_str(line: &str) -> Result<Self, Self::Err> {
        let line = line.trim();
        let (keyword, rest) = split_first_word(line);
        match keyword {
            "NAVIGATE" => {
                let url = require_arg(rest, "NAVIGATE", "url")?;
                Ok(ServerPush::Navigate {
                    url: url.to_string(),
                })
            }
            _ => Err(ProtocolError::UnknownResponse(line.to_string())),
        }
    }
}

impl fmt::Display for ServerPush {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ServerPush::Navigate { url } => write!(f, "NAVIGATE {url}"),
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Split a string at the first whitespace, returning (first_word, rest).
/// If there's no whitespace, rest is empty.
fn split_first_word(s: &str) -> (&str, &str) {
    match s.find(char::is_whitespace) {
        Some(pos) => (&s[..pos], s[pos..].trim_start()),
        None => (s, ""),
    }
}

/// Require that `rest` is non-empty, returning it, or produce a MissingArgument error.
fn require_arg<'a>(
    rest: &'a str,
    command: &'static str,
    expected: &'static str,
) -> Result<&'a str, ProtocolError> {
    if rest.is_empty() {
        Err(ProtocolError::MissingArgument { command, expected })
    } else {
        Ok(rest)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- Command round-trip tests --

    fn assert_command_roundtrip(input: &str) {
        let cmd: Command = input.parse().unwrap();
        let serialized = cmd.to_string();
        let reparsed: Command = serialized.parse().unwrap();
        assert_eq!(cmd, reparsed, "round-trip failed for: {input}");
    }

    #[test]
    fn command_register_roundtrip() {
        assert_command_roundtrip("register myhost");
    }

    #[test]
    fn command_open_roundtrip() {
        assert_command_roundtrip("open myhost https://example.com/path?q=1&r=2");
    }

    #[test]
    fn command_open_on_roundtrip() {
        assert_command_roundtrip("open-on work https://example.com");
    }

    #[test]
    fn command_test_roundtrip() {
        assert_command_roundtrip("test https://example.com/foo");
    }

    #[test]
    fn command_get_config_roundtrip() {
        assert_command_roundtrip("get-config");
    }

    #[test]
    fn command_set_config_roundtrip() {
        assert_command_roundtrip(r#"set-config {"socket":"/run/test.sock"}"#);
    }

    #[test]
    fn command_add_rule_roundtrip() {
        assert_command_roundtrip(r#"add-rule {"pattern":".*","tenant":"work"}"#);
    }

    #[test]
    fn command_update_rule_roundtrip() {
        assert_command_roundtrip(r#"update-rule 2 {"pattern":".*","tenant":"work"}"#);
    }

    #[test]
    fn command_delete_rule_roundtrip() {
        assert_command_roundtrip("delete-rule 3");
    }

    #[test]
    fn command_status_roundtrip() {
        assert_command_roundtrip("status");
    }

    // -- Command parse edge cases --

    #[test]
    fn command_url_with_spaces_preserved() {
        // URLs shouldn't have spaces, but rest-of-line parsing preserves them
        let cmd: Command = "test https://example.com/path with spaces".parse().unwrap();
        assert_eq!(
            cmd,
            Command::Test {
                url: "https://example.com/path with spaces".to_string()
            }
        );
    }

    #[test]
    fn command_empty_line_error() {
        assert!("".parse::<Command>().is_err());
    }

    #[test]
    fn command_unknown_keyword_error() {
        assert!("unknown-cmd arg".parse::<Command>().is_err());
    }

    #[test]
    fn command_missing_args_error() {
        assert!("register".parse::<Command>().is_err());
        assert!("open".parse::<Command>().is_err());
        assert!("open myhost".parse::<Command>().is_err());
        assert!("test".parse::<Command>().is_err());
    }

    // -- Response round-trip tests --

    fn assert_response_roundtrip(input: &str) {
        let resp: Response = input.parse().unwrap();
        let serialized = resp.to_string();
        let reparsed: Response = serialized.parse().unwrap();
        assert_eq!(resp, reparsed, "round-trip failed for: {input}");
    }

    #[test]
    fn response_ok_roundtrip() {
        assert_response_roundtrip("OK");
    }

    #[test]
    fn response_error_roundtrip() {
        assert_response_roundtrip("ERR something went wrong");
    }

    #[test]
    fn response_local_roundtrip() {
        assert_response_roundtrip("LOCAL");
    }

    #[test]
    fn response_remote_roundtrip() {
        assert_response_roundtrip("REMOTE work-container");
    }

    #[test]
    fn response_match_roundtrip() {
        assert_response_roundtrip("MATCH work-container 2");
    }

    #[test]
    fn response_nomatch_roundtrip() {
        assert_response_roundtrip("NOMATCH local");
    }

    #[test]
    fn response_config_roundtrip() {
        assert_response_roundtrip(r#"CONFIG {"socket":"/run/test.sock"}"#);
    }

    #[test]
    fn response_status_roundtrip() {
        assert_response_roundtrip(r#"STATUS {"registered":["host1"]}"#);
    }

    // -- ServerPush round-trip tests --

    #[test]
    fn server_push_navigate_roundtrip() {
        let input = "NAVIGATE https://example.com/path?q=1";
        let push: ServerPush = input.parse().unwrap();
        let serialized = push.to_string();
        let reparsed: ServerPush = serialized.parse().unwrap();
        assert_eq!(push, reparsed);
    }

    #[test]
    fn server_push_unknown_error() {
        assert!("UNKNOWN https://example.com".parse::<ServerPush>().is_err());
    }
}
