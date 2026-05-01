//! Chrome native messaging length-prefixed framing.
//!
//! Chrome sends/receives messages as: [4-byte little-endian length][UTF-8 JSON bytes].
//! This module handles reading and writing that framing on stdin/stdout.

use std::io::{self, Read, Write};

/// Read a length-prefixed message from the given reader.
///
/// Returns the raw JSON bytes (without the length prefix).
pub fn read_message(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf) as usize;

    if len > 1024 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("message too large: {len} bytes"),
        ));
    }

    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    Ok(buf)
}

/// Write a length-prefixed message to the given writer.
pub fn write_message(writer: &mut impl Write, json: &[u8]) -> io::Result<()> {
    let len = json.len() as u32;
    writer.write_all(&len.to_le_bytes())?;
    writer.write_all(json)?;
    writer.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn roundtrip_message() {
        let msg = b"{\"cmd\":\"status\"}";
        let mut buf = Vec::new();
        write_message(&mut buf, msg).unwrap();

        let mut cursor = Cursor::new(buf);
        let read_back = read_message(&mut cursor).unwrap();
        assert_eq!(read_back, msg);
    }

    #[test]
    fn message_too_large_is_rejected() {
        // Create a length header claiming 2MB
        let len_buf = (2 * 1024 * 1024u32).to_le_bytes();
        let mut cursor = Cursor::new(len_buf.to_vec());
        let result = read_message(&mut cursor);
        assert!(result.is_err());
    }
}
