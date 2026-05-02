//! Translation between Chrome extension JSON messages and socket protocol lines.
//!
//! Pure functions that convert between the JSON format used by the browser
//! extension (via native messaging) and the line-based protocol used by
//! the daemon socket. No I/O.

use serde_json::{json, Value};
use thiserror::Error;
use url_router_protocol::protocol::{Response, ServerPush};
use url_router_protocol::types::TenantId;

/// Errors from message translation.
#[derive(Debug, Error)]
pub enum TranslateError {
    #[error("missing required field: {0}")]
    MissingField(&'static str),

    #[error("unknown action: {0}")]
    UnknownAction(String),

    #[error("protocol parse error: {0}")]
    Protocol(#[from] url_router_protocol::protocol::ProtocolError),
}

/// Convert a JSON message from the extension into a protocol command line.
///
/// The `tenant_id` is injected into commands that require a source tenant
/// (e.g., `open`). The extension doesn't know its own tenant ID — the
/// native messaging host provides it from `gethostname()`.
pub fn json_to_command(value: &Value, tenant_id: &TenantId) -> Result<String, TranslateError> {
    let action = value
        .get("cmd")
        .and_then(|v| v.as_str())
        .ok_or(TranslateError::MissingField("cmd"))?;

    match action {
        "open" => {
            let url = value
                .get("url")
                .and_then(|v| v.as_str())
                .ok_or(TranslateError::MissingField("url"))?;
            Ok(format!("open {tenant_id} {url}"))
        }
        "open-on" => {
            let target = value
                .get("tenant")
                .and_then(|v| v.as_str())
                .ok_or(TranslateError::MissingField("tenant"))?;
            let url = value
                .get("url")
                .and_then(|v| v.as_str())
                .ok_or(TranslateError::MissingField("url"))?;
            Ok(format!("open-on {target} {url}"))
        }
        "test" => {
            let url = value
                .get("url")
                .and_then(|v| v.as_str())
                .ok_or(TranslateError::MissingField("url"))?;
            Ok(format!("test {url}"))
        }
        "add-rule" => {
            let rule = value
                .get("rule")
                .ok_or(TranslateError::MissingField("rule"))?;
            Ok(format!("add-rule {rule}"))
        }
        "set-config" => {
            let config = value
                .get("config")
                .ok_or(TranslateError::MissingField("config"))?;
            Ok(format!("set-config {config}"))
        }
        "get-config" => Ok("get-config".to_string()),
        "status" => Ok("status".to_string()),
        other => Err(TranslateError::UnknownAction(other.to_string())),
    }
}

/// Convert a protocol response line into a JSON value for the extension.
pub fn response_to_json(line: &str) -> Result<Value, TranslateError> {
    let response: Response = line.parse()?;
    Ok(match response {
        Response::Ok => json!({"status": "OK"}),
        Response::Error { message } => json!({"status": "ERR", "message": message}),
        Response::Local => json!({"status": "LOCAL"}),
        Response::Remote { tenant_id } => json!({"status": "REMOTE", "tenant": tenant_id.as_str()}),
        Response::Match {
            tenant_id,
            rule_index,
        } => {
            json!({"status": "MATCH", "tenant": tenant_id.as_str(), "ruleIndex": rule_index.value()})
        }
        Response::NoMatch { default_tenant } => {
            json!({"status": "NOMATCH", "defaultTenant": default_tenant.as_str()})
        }
        Response::Config { json: config_json } => {
            let data: Value =
                serde_json::from_str(&config_json).unwrap_or(Value::String(config_json));
            json!({"status": "CONFIG", "data": data})
        }
        Response::Status { json: status_json } => {
            let data: Value =
                serde_json::from_str(&status_json).unwrap_or(Value::String(status_json));
            json!({"status": "STATUS", "data": data})
        }
    })
}

/// Convert a NAVIGATE server push into a JSON value for the extension.
pub fn navigate_to_json(url: &str) -> Value {
    json!({"status": "NAVIGATE", "url": url})
}

/// Parse a server push line into its URL, if it's a NAVIGATE push.
pub fn parse_server_push(line: &str) -> Result<String, TranslateError> {
    let push: ServerPush = line.parse()?;
    match push {
        ServerPush::Navigate { url } => Ok(url),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tid(s: &str) -> TenantId {
        TenantId::from(s.to_string())
    }

    #[test]
    fn json_to_command_open() {
        let json = json!({"cmd": "open", "url": "https://example.com"});
        let cmd = json_to_command(&json, &tid("myhost")).unwrap();
        assert_eq!(cmd, "open myhost https://example.com");
    }

    #[test]
    fn json_to_command_open_on() {
        let json = json!({"cmd": "open-on", "tenant": "work", "url": "https://example.com"});
        let cmd = json_to_command(&json, &tid("myhost")).unwrap();
        assert_eq!(cmd, "open-on work https://example.com");
    }

    #[test]
    fn json_to_command_test() {
        let json = json!({"cmd": "test", "url": "https://example.com"});
        let cmd = json_to_command(&json, &tid("myhost")).unwrap();
        assert_eq!(cmd, "test https://example.com");
    }

    #[test]
    fn json_to_command_get_config() {
        let json = json!({"cmd": "get-config"});
        let cmd = json_to_command(&json, &tid("myhost")).unwrap();
        assert_eq!(cmd, "get-config");
    }

    #[test]
    fn json_to_command_set_config() {
        let json = json!({"cmd": "set-config", "config": {"socket": "/tmp/test.sock", "tenants": {}, "rules": [], "defaults": {}}});
        let cmd = json_to_command(&json, &tid("myhost")).unwrap();
        assert!(cmd.starts_with("set-config "));
    }

    #[test]
    fn json_to_command_status() {
        let json = json!({"cmd": "status"});
        let cmd = json_to_command(&json, &tid("myhost")).unwrap();
        assert_eq!(cmd, "status");
    }

    #[test]
    fn json_to_command_unknown() {
        let json = json!({"cmd": "bad"});
        assert!(json_to_command(&json, &tid("myhost")).is_err());
    }

    #[test]
    fn json_to_command_missing_cmd() {
        let json = json!({"url": "https://example.com"});
        assert!(json_to_command(&json, &tid("myhost")).is_err());
    }

    #[test]
    fn response_to_json_local() {
        let json = response_to_json("LOCAL").unwrap();
        assert_eq!(json["status"], "LOCAL");
    }

    #[test]
    fn response_to_json_remote() {
        let json = response_to_json("REMOTE work").unwrap();
        assert_eq!(json["status"], "REMOTE");
        assert_eq!(json["tenant"], "work");
    }

    #[test]
    fn response_to_json_ok() {
        let json = response_to_json("OK").unwrap();
        assert_eq!(json["status"], "OK");
    }

    #[test]
    fn response_to_json_error() {
        let json = response_to_json("ERR something failed").unwrap();
        assert_eq!(json["status"], "ERR");
        assert_eq!(json["message"], "something failed");
    }

    #[test]
    fn navigate_json_format() {
        let json = navigate_to_json("https://example.com");
        assert_eq!(json["status"], "NAVIGATE");
        assert_eq!(json["url"], "https://example.com");
    }

    #[test]
    fn parse_navigate_push() {
        let url = parse_server_push("NAVIGATE https://example.com/path").unwrap();
        assert_eq!(url, "https://example.com/path");
    }
}
