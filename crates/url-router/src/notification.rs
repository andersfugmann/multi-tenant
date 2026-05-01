//! Desktop notification sending.
//!
//! Thin wrapper around `notify-rust` for showing routing notifications.

use notify_rust::Notification;

/// Show a desktop notification about a routing decision.
pub fn show_routing_notification(
    summary: &str,
    body: &str,
    timeout_ms: u32,
) -> Result<(), notify_rust::error::Error> {
    Notification::new()
        .summary(summary)
        .body(body)
        .timeout(timeout_ms as i32)
        .show()?;
    Ok(())
}
