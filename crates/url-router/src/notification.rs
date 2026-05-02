//! Desktop notification sending.
//!
//! Thin wrapper around `notify-rust` for sending routing notifications.

use thiserror::Error;

/// Errors from notification sending.
#[derive(Debug, Error)]
pub enum NotificationError {
    #[error("failed to send notification: {0}")]
    Send(#[from] notify_rust::error::Error),
}

/// Send a desktop notification about a routing decision.
pub fn send_routing_notification(
    summary: &str,
    body: &str,
    timeout_ms: u64,
) -> Result<(), NotificationError> {
    notify_rust::Notification::new()
        .summary(summary)
        .body(body)
        .timeout(notify_rust::Timeout::Milliseconds(timeout_ms as u32))
        .show()?;
    Ok(())
}
