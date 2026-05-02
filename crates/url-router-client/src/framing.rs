//! Chrome native messaging length-prefixed framing.
//!
//! Implements the Chrome native messaging protocol: each message is
//! a JSON value preceded by a 4-byte little-endian length prefix.
//! This module handles only the framing layer, not message content.

use std::io::{Read, Write};

use serde_json::Value;
use thiserror::Error;

/// Errors from native messaging framing operations.
#[derive(Debug, Error)]
pub enum FramingError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("message too large: {0} bytes (max 1MB)")]
    TooLarge(usize),
}

const MAX_MESSAGE_SIZE: usize = 1024 * 1024; // 1 MB

/// Read a length-prefixed JSON message from a reader.
///
/// Format: 4-byte LE u32 length, followed by `length` bytes of UTF-8 JSON.
pub fn read_message<R: Read>(reader: &mut R) -> Result<Value, FramingError> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf) as usize;

    if len > MAX_MESSAGE_SIZE {
        return Err(FramingError::TooLarge(len));
    }

    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    let value = serde_json::from_slice(&buf)?;
    Ok(value)
}

/// Write a length-prefixed JSON message to a writer.
///
/// Format: 4-byte LE u32 length, followed by the JSON bytes.
pub fn write_message<W: Write>(writer: &mut W, value: &Value) -> Result<(), FramingError> {
    let json = serde_json::to_vec(value)?;
    if json.len() > MAX_MESSAGE_SIZE {
        return Err(FramingError::TooLarge(json.len()));
    }
    let len = json.len() as u32;
    writer.write_all(&len.to_le_bytes())?;
    writer.write_all(&json)?;
    writer.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn roundtrip_simple_message() {
        let value = serde_json::json!({"action": "open", "url": "https://example.com"});
        let mut buf = Vec::new();
        write_message(&mut buf, &value).unwrap();

        let mut cursor = Cursor::new(buf);
        let read_value = read_message(&mut cursor).unwrap();
        assert_eq!(value, read_value);
    }

    #[test]
    fn roundtrip_empty_object() {
        let value = serde_json::json!({});
        let mut buf = Vec::new();
        write_message(&mut buf, &value).unwrap();

        let mut cursor = Cursor::new(buf);
        let read_value = read_message(&mut cursor).unwrap();
        assert_eq!(value, read_value);
    }

    #[test]
    fn rejects_too_large() {
        // Craft a length header claiming 2MB
        let len_bytes = (2_000_000u32).to_le_bytes();
        let mut cursor = Cursor::new(len_bytes.to_vec());
        let err = read_message(&mut cursor).unwrap_err();
        assert!(matches!(err, FramingError::TooLarge(_)));
    }

    #[test]
    fn correct_length_prefix() {
        let value = serde_json::json!({"a": 1});
        let mut buf = Vec::new();
        write_message(&mut buf, &value).unwrap();

        let len = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        assert_eq!(len, buf.len() - 4);
    }
}
