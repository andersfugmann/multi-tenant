//! Oneshot channel implementation using `std::sync::mpsc`.
//!
//! Provides a simple oneshot channel for sending a single response from
//! the coordinator thread back to a connection thread. No async runtime needed.

use std::sync::mpsc;

/// Create a new oneshot channel pair.
pub fn channel<T>() -> (Sender<T>, Receiver<T>) {
    let (tx, rx) = mpsc::sync_channel(1);
    (Sender(tx), Receiver(rx))
}

/// Sending half of a oneshot channel. Consumed on send.
pub struct Sender<T>(mpsc::SyncSender<T>);

impl<T> Sender<T> {
    /// Send a value, consuming the sender. Returns the value back on failure.
    pub fn send(self, value: T) -> Result<(), T> {
        self.0.send(value).map_err(|e| e.0)
    }
}

/// Receiving half of a oneshot channel. Consumed on recv.
pub struct Receiver<T>(mpsc::Receiver<T>);

impl<T> Receiver<T> {
    /// Block until a value is received, consuming the receiver.
    pub fn recv(self) -> Result<T, mpsc::RecvError> {
        self.0.recv()
    }
}
