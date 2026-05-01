//! Translation between Chrome JSON messages and daemon line protocol.
//!
//! Pure functions — no I/O. Takes bytes/strings in, returns bytes/strings out.

use serde_json::Value;

/// Convert a Chrome JSON message (bytes) into a daemon line command (string).
///
/// JSON format: `{"cmd": "open", "url": "..."}`
pub fn json_to_line(json_bytes: &[u8]) -> Result<String, String> {
    let value: Value =
        serde_json::from_slice(json_bytes).map_err(|e| format!("invalid JSON: {e}"))?;

    let cmd = value
        .get("cmd")
        .and_then(|v| v.as_str())
        .ok_or("missing 'cmd' field")?;

    match cmd {
        "open" => {
            let url = value
                .get("url")
                .and_then(|v| v.as_str())
                .ok_or("missing 'url' field")?;
            Ok(format!("open {url}"))
        }
        "open-on" => {
            let tenant = value
                .get("tenant")
                .and_then(|v| v.as_str())
                .ok_or("missing 'tenant' field")?;
            let url = value
                .get("url")
                .and_then(|v| v.as_str())
                .ok_or("missing 'url' field")?;
            Ok(format!("open-on {tenant} {url}"))
        }
        "add-rule" => {
            let rule = value
                .get("rule")
                .ok_or("missing 'rule' field")?;
            let rule_json = serde_json::to_string(rule)
                .map_err(|e| format!("failed to serialize rule: {e}"))?;
            Ok(format!("add-rule {rule_json}"))
        }
        "test" => {
            let url = value
                .get("url")
                .and_then(|v| v.as_str())
                .ok_or("missing 'url' field")?;
            Ok(format!("test {url}"))
        }
        "get-config" => Ok("get-config".into()),
        "status" => Ok("status".into()),
        other => Err(format!("unknown cmd: {other}")),
    }
}

/// Convert a daemon line response (string) into Chrome JSON bytes.
pub fn line_to_json(line: &str) -> Vec<u8> {
    let line = line.trim();

    let value = match line {
        "LOCAL" => serde_json::json!({"status": "LOCAL"}),
        "FALLBACK" => serde_json::json!({"status": "FALLBACK"}),
        "OK" => serde_json::json!({"status": "OK"}),
        "OK local" => serde_json::json!({"status": "OK", "detail": "local"}),
        "OK fallback" => serde_json::json!({"status": "OK", "detail": "fallback"}),
        _ if line.starts_with("REMOTE ") => {
            let tenant = &line["REMOTE ".len()..];
            serde_json::json!({"status": "REMOTE", "tenant": tenant})
        }
        _ if line.starts_with("OK forwarded ") => {
            let tenant = &line["OK forwarded ".len()..];
            serde_json::json!({"status": "OK", "detail": format!("forwarded {tenant}")})
        }
        _ if line.starts_with("MATCH ") => {
            let rest = &line["MATCH ".len()..];
            let parts: Vec<&str> = rest.splitn(2, ' ').collect();
            if parts.len() == 2 {
                serde_json::json!({"status": "MATCH", "tenant": parts[0], "rule_index": parts[1]})
            } else {
                serde_json::json!({"status": "MATCH", "raw": rest})
            }
        }
        _ if line.starts_with("NOMATCH ") => {
            let default = &line["NOMATCH ".len()..];
            serde_json::json!({"status": "NOMATCH", "default": default})
        }
        _ if line.starts_with("CONFIG ") => {
            let json_str = &line["CONFIG ".len()..];
            if let Ok(data) = serde_json::from_str::<Value>(json_str) {
                serde_json::json!({"status": "CONFIG", "data": data})
            } else {
                serde_json::json!({"status": "CONFIG", "data": json_str})
            }
        }
        _ if line.starts_with("STATUS ") => {
            let json_str = &line["STATUS ".len()..];
            if let Ok(data) = serde_json::from_str::<Value>(json_str) {
                serde_json::json!({"status": "STATUS", "data": data})
            } else {
                serde_json::json!({"status": "STATUS", "data": json_str})
            }
        }
        _ if line.starts_with("ERR ") => {
            let msg = &line["ERR ".len()..];
            serde_json::json!({"status": "ERR", "message": msg})
        }
        _ => serde_json::json!({"status": "ERR", "message": format!("unknown response: {line}")}),
    };

    serde_json::to_vec(&value).unwrap_or_else(|_| b"{}".to_vec())
}

/// Create a JSON error response.
pub fn error_response(message: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({"status": "ERR", "message": message}))
        .unwrap_or_else(|_| b"{}".to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_to_line_open() {
        let json = br#"{"cmd": "open", "url": "https://github.com"}"#;
        let result = json_to_line(json).unwrap();
        assert_eq!(result, "open https://github.com");
    }

    #[test]
    fn json_to_line_open_on() {
        let json = br#"{"cmd": "open-on", "tenant": "work", "url": "https://example.com"}"#;
        let result = json_to_line(json).unwrap();
        assert_eq!(result, "open-on work https://example.com");
    }

    #[test]
    fn json_to_line_add_rule() {
        let json = br#"{"cmd": "add-rule", "rule": {"pattern": "^https://x\\.com", "tenant": "work"}}"#;
        let result = json_to_line(json).unwrap();
        assert!(result.starts_with("add-rule "));
        assert!(result.contains("pattern"));
    }

    #[test]
    fn json_to_line_get_config() {
        let json = br#"{"cmd": "get-config"}"#;
        assert_eq!(json_to_line(json).unwrap(), "get-config");
    }

    #[test]
    fn json_to_line_status() {
        let json = br#"{"cmd": "status"}"#;
        assert_eq!(json_to_line(json).unwrap(), "status");
    }

    #[test]
    fn json_to_line_unknown_cmd() {
        let json = br#"{"cmd": "foobar"}"#;
        assert!(json_to_line(json).is_err());
    }

    #[test]
    fn line_to_json_local() {
        let result = line_to_json("LOCAL");
        let v: Value = serde_json::from_slice(&result).unwrap();
        assert_eq!(v["status"], "LOCAL");
    }

    #[test]
    fn line_to_json_remote() {
        let result = line_to_json("REMOTE work");
        let v: Value = serde_json::from_slice(&result).unwrap();
        assert_eq!(v["status"], "REMOTE");
        assert_eq!(v["tenant"], "work");
    }

    #[test]
    fn line_to_json_ok_forwarded() {
        let result = line_to_json("OK forwarded host");
        let v: Value = serde_json::from_slice(&result).unwrap();
        assert_eq!(v["status"], "OK");
        assert_eq!(v["detail"], "forwarded host");
    }

    #[test]
    fn line_to_json_err() {
        let result = line_to_json("ERR something broke");
        let v: Value = serde_json::from_slice(&result).unwrap();
        assert_eq!(v["status"], "ERR");
        assert_eq!(v["message"], "something broke");
    }
}
