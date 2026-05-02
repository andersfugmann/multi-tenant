//! Single-threaded coordinator that owns all mutable daemon state.
//!
//! Receives messages via `mpsc` channel from connection threads, the config
//! watcher, and launch-timeout timers. Processes each message synchronously.
//! No locks, no mutexes — all shared state lives here.

use std::collections::HashMap;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde::Serialize;
use url_router_protocol::config::Config;
use url_router_protocol::matching;
use url_router_protocol::protocol::{Command, Response};
use url_router_protocol::types::{RuleIndex, TenantId};

use crate::browser;
use crate::notification;
use crate::oneshot;

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// Messages sent to the coordinator from other threads.
pub enum CoordinatorMessage {
    /// A parsed command from a connection thread, with a oneshot for the response.
    Command {
        command: Command,
        respond: oneshot::Sender<Response>,
    },
    /// A client is registering as a listener for a tenant.
    Register {
        tenant_id: TenantId,
        stream: UnixStream,
        respond: oneshot::Sender<Response>,
    },
    /// A registered listener disconnected.
    Unregister { tenant_id: TenantId },
    /// The config file was reloaded.
    ConfigReloaded { config: Config },
    /// A browser launch timed out.
    #[allow(dead_code)]
    LaunchTimeout { tenant_id: TenantId },
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Status information returned by the `status` command.
#[derive(Debug, Clone, Serialize)]
struct StatusInfo {
    registered: Vec<String>,
    launching: Vec<String>,
    rules: usize,
    tenants: usize,
}

/// Tenant connection state: either registered (has a stream for pushes)
/// or launching (browser started, waiting for registration).
enum TenantState {
    Registered(UnixStream),
    Launching { pending_urls: Vec<String> },
}

struct CoordinatorState {
    config: Config,
    tenant_states: HashMap<TenantId, TenantState>,
    /// Cooldown tracking: (destination tenant, url) → last push time
    cooldowns: HashMap<(TenantId, String), Instant>,
}

impl CoordinatorState {
    fn new(config: Config) -> Self {
        Self {
            config,
            tenant_states: HashMap::new(),
            cooldowns: HashMap::new(),
        }
    }

    // -- Routing --

    fn handle_command(&mut self, command: Command) -> Response {
        match command {
            Command::Open { tenant_id, url } => self.handle_open(tenant_id, url),
            Command::OpenOn { tenant_id, url } => self.handle_open_on(tenant_id, url),
            Command::Test { url } => self.handle_test(&url),
            Command::GetConfig => self.handle_get_config(),
            Command::SetConfig { json } => self.handle_set_config(&json),
            Command::AddRule { json } => self.handle_add_rule(&json),
            Command::UpdateRule { index, json } => self.handle_update_rule(index, &json),
            Command::DeleteRule { index } => self.handle_delete_rule(index),
            Command::Status => self.handle_status(),
            Command::Register { .. } => Response::Error {
                message: "register handled separately".to_string(),
            },
        }
    }

    fn handle_open(&mut self, source: TenantId, url: String) -> Response {
        if source.is_default() {
            // CLI mode: evaluate rules, always route remotely
            let target = self.evaluate_rules(&url);
            if target.is_local() {
                return Response::Error {
                    message: "no matching rule and default is local".to_string(),
                };
            }
            self.push_navigate(&target, &url);
            self.maybe_notify(&source, &target, &url);
            Response::Remote { tenant_id: target }
        } else {
            // Extension mode: check cooldown, then evaluate
            if self.is_on_cooldown(&source, &url) {
                return Response::Local;
            }
            let target = self.evaluate_rules(&url);
            if target.is_local() || target == source {
                Response::Local
            } else {
                self.push_navigate(&target, &url);
                self.maybe_notify(&source, &target, &url);
                Response::Remote { tenant_id: target }
            }
        }
    }

    fn handle_open_on(&mut self, target: TenantId, url: String) -> Response {
        if !self.config.tenants.contains_key(&target) {
            return Response::Error {
                message: format!("unknown tenant: {target}"),
            };
        }
        self.push_navigate(&target, &url);
        Response::Remote { tenant_id: target }
    }

    fn handle_test(&self, url: &str) -> Response {
        match matching::match_url(url, &self.config.rules) {
            Some((tenant_id, rule_index)) => Response::Match {
                tenant_id,
                rule_index,
            },
            None => Response::NoMatch {
                default_tenant: self.config.defaults.unmatched.clone(),
            },
        }
    }

    fn handle_get_config(&self) -> Response {
        match serde_json::to_string(&self.config) {
            Ok(json) => Response::Config { json },
            Err(e) => Response::Error {
                message: format!("failed to serialize config: {e}"),
            },
        }
    }

    fn handle_set_config(&mut self, json: &str) -> Response {
        match Config::from_json(json) {
            Ok(config) => {
                self.config = config;
                tracing::info!("config replaced via set-config command");
                Response::Ok
            }
            Err(e) => Response::Error {
                message: format!("invalid config: {e}"),
            },
        }
    }

    fn handle_add_rule(&mut self, json: &str) -> Response {
        match Config::parse_rule(json, &self.config.tenants) {
            Ok(rule) => {
                self.config.rules.push(rule);
                tracing::info!("rule added via add-rule command");
                Response::Ok
            }
            Err(e) => Response::Error {
                message: format!("invalid rule: {e}"),
            },
        }
    }

    fn handle_update_rule(&mut self, index: RuleIndex, json: &str) -> Response {
        let idx = index.value();
        if idx >= self.config.rules.len() {
            return Response::Error {
                message: format!("rule index {idx} out of range"),
            };
        }
        match Config::parse_rule(json, &self.config.tenants) {
            Ok(rule) => {
                self.config.rules[idx] = rule;
                tracing::info!(index = idx, "rule updated via update-rule command");
                Response::Ok
            }
            Err(e) => Response::Error {
                message: format!("invalid rule: {e}"),
            },
        }
    }

    fn handle_delete_rule(&mut self, index: RuleIndex) -> Response {
        let idx = index.value();
        if idx >= self.config.rules.len() {
            return Response::Error {
                message: format!("rule index {idx} out of range"),
            };
        }
        self.config.rules.remove(idx);
        tracing::info!(index = idx, "rule deleted via delete-rule command");
        Response::Ok
    }

    fn handle_status(&self) -> Response {
        let mut registered = Vec::new();
        let mut launching = Vec::new();
        for (tid, state) in &self.tenant_states {
            match state {
                TenantState::Registered(_) => registered.push(tid.to_string()),
                TenantState::Launching { .. } => launching.push(tid.to_string()),
            }
        }
        let info = StatusInfo {
            registered,
            launching,
            rules: self.config.rules.len(),
            tenants: self.config.tenants.len(),
        };
        match serde_json::to_string(&info) {
            Ok(json) => Response::Status { json },
            Err(e) => Response::Error {
                message: format!("failed to serialize status: {e}"),
            },
        }
    }

    // -- Registration --

    fn handle_register(&mut self, tenant_id: TenantId, stream: UnixStream) -> Response {
        if !tenant_id.is_valid() {
            return Response::Error {
                message: format!("invalid tenant ID: {tenant_id}"),
            };
        }

        // Collect pending URLs from a prior launch, if any
        let pending_urls = match self.tenant_states.remove(&tenant_id) {
            Some(TenantState::Launching { pending_urls }) => pending_urls,
            _ => Vec::new(),
        };

        self.tenant_states
            .insert(tenant_id.clone(), TenantState::Registered(stream));
        tracing::info!(tenant = %tenant_id, "tenant registered");

        // Deliver any URLs that were queued while the browser was launching
        for url in &pending_urls {
            self.write_navigate_to_tenant(&tenant_id, url);
        }

        Response::Ok
    }

    fn handle_unregister(&mut self, tenant_id: &TenantId) {
        self.tenant_states.remove(tenant_id);
        tracing::info!(tenant = %tenant_id, "tenant unregistered");
    }

    // -- Helpers --

    fn evaluate_rules(&self, url: &str) -> TenantId {
        match matching::match_url(url, &self.config.rules) {
            Some((tenant_id, rule_index)) => {
                tracing::info!(url = url, tenant = %tenant_id, rule_index = rule_index.value(), "rule matched");
                tenant_id
            }
            None => {
                tracing::debug!(url = url, default = %self.config.defaults.unmatched, "no rule matched, using default");
                self.config.defaults.unmatched.clone()
            }
        }
    }

    fn is_on_cooldown(&self, destination: &TenantId, url: &str) -> bool {
        let key = (destination.clone(), url.to_string());
        if let Some(last) = self.cooldowns.get(&key) {
            let elapsed = last.elapsed();
            let cooldown = Duration::from_secs(self.config.defaults.cooldown_secs);
            if elapsed < cooldown {
                tracing::debug!(
                    tenant = %destination,
                    url = url,
                    remaining_ms = (cooldown - elapsed).as_millis() as u64,
                    "cooldown active"
                );
                return true;
            }
        }
        false
    }

    fn set_cooldown(&mut self, destination: &TenantId, url: &str) {
        self.cooldowns
            .insert((destination.clone(), url.to_string()), Instant::now());
    }

    fn push_navigate(&mut self, target: &TenantId, url: &str) {
        self.set_cooldown(target, url);

        match self.tenant_states.get_mut(target) {
            Some(TenantState::Registered(_)) => {
                self.write_navigate_to_tenant(target, url);
            }
            Some(TenantState::Launching { pending_urls }) => {
                tracing::debug!(tenant = %target, url = url, "queuing URL for launching tenant");
                pending_urls.push(url.to_string());
            }
            None => {
                self.launch_browser_for_tenant(target, url);
            }
        }
    }

    fn write_navigate_to_tenant(&mut self, target: &TenantId, url: &str) {
        if let Some(TenantState::Registered(stream)) = self.tenant_states.get_mut(target) {
            let line = format!("NAVIGATE {url}\n");
            if let Err(error) = stream.write_all(line.as_bytes()) {
                tracing::error!(tenant = %target, %error, "failed to push NAVIGATE, removing tenant");
                self.tenant_states.remove(target);
            } else {
                tracing::debug!(tenant = %target, url = url, "pushed NAVIGATE");
            }
        }
    }

    fn launch_browser_for_tenant(&mut self, target: &TenantId, url: &str) {
        let Some(tenant_config) = self.config.tenants.get(target) else {
            tracing::warn!(tenant = %target, "cannot launch browser: no config for tenant");
            return;
        };

        match browser::launch_browser(&tenant_config.browser_cmd, url) {
            Ok(_child) => {
                tracing::info!(tenant = %target, url = url, "launched browser");
                self.tenant_states.insert(
                    target.clone(),
                    TenantState::Launching {
                        pending_urls: Vec::new(),
                    },
                );
            }
            Err(error) => {
                tracing::error!(tenant = %target, %error, "failed to launch browser");
            }
        }
    }

    fn maybe_notify(&self, source: &TenantId, target: &TenantId, url: &str) {
        if !self.config.defaults.notifications {
            return;
        }
        let summary = "URL Routed";
        let body = format!("From {source} → {target}\n{url}");
        if let Err(error) = notification::send_routing_notification(
            summary,
            &body,
            self.config.defaults.notification_timeout_ms,
        ) {
            tracing::warn!(%error, "failed to send notification");
        }
    }

    fn cleanup_expired_cooldowns(&mut self) {
        let cooldown = Duration::from_secs(self.config.defaults.cooldown_secs);
        self.cooldowns
            .retain(|_, instant| instant.elapsed() < cooldown);
    }
}

// ---------------------------------------------------------------------------
// Coordinator loop
// ---------------------------------------------------------------------------

/// Run the coordinator loop. This blocks forever, processing messages.
///
/// All mutable daemon state is owned by this function. Other threads
/// communicate via the returned `mpsc::Sender`.
pub fn run_coordinator(rx: mpsc::Receiver<CoordinatorMessage>, config: Config) {
    let mut state = CoordinatorState::new(config);
    let mut cleanup_counter = 0u64;

    while let Ok(message) = rx.recv() {
        match message {
            CoordinatorMessage::Command { command, respond } => {
                let response = state.handle_command(command);
                let _ = respond.send(response);
            }
            CoordinatorMessage::Register {
                tenant_id,
                stream,
                respond,
            } => {
                let response = state.handle_register(tenant_id, stream);
                let _ = respond.send(response);
            }
            CoordinatorMessage::Unregister { tenant_id } => {
                state.handle_unregister(&tenant_id);
            }
            CoordinatorMessage::ConfigReloaded { config } => {
                tracing::info!("config reloaded by watcher");
                state.config = config;
            }
            CoordinatorMessage::LaunchTimeout { tenant_id } => {
                if let Some(TenantState::Launching { pending_urls }) =
                    state.tenant_states.get(&tenant_id)
                {
                    tracing::warn!(
                        tenant = %tenant_id,
                        pending = pending_urls.len(),
                        "browser launch timed out, dropping pending URLs"
                    );
                    state.tenant_states.remove(&tenant_id);
                }
            }
        }

        // Periodic cooldown cleanup (every 100 messages)
        cleanup_counter += 1;
        if cleanup_counter.is_multiple_of(100) {
            state.cleanup_expired_cooldowns();
        }
    }

    tracing::info!("coordinator shutting down");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config() -> Config {
        Config::from_json(
            r#"{
                "tenants": {
                    "personal": { "browser_cmd": "echo" },
                    "work": { "browser_cmd": "echo" }
                },
                "rules": [
                    { "pattern": ".*\\.work\\.com", "tenant": "work" },
                    { "pattern": ".*\\.personal\\.io", "tenant": "personal" }
                ],
                "defaults": {
                    "unmatched": "local",
                    "cooldown_secs": 1
                }
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn test_open_from_default_routes_remotely() {
        let mut state = CoordinatorState::new(test_config());
        let response = state.handle_open(
            TenantId::from("default".to_string()),
            "https://app.work.com".to_string(),
        );
        assert_eq!(
            response,
            Response::Remote {
                tenant_id: TenantId::from("work".to_string())
            }
        );
    }

    #[test]
    fn test_open_from_default_with_local_default_returns_error() {
        let mut state = CoordinatorState::new(test_config());
        let response = state.handle_open(
            TenantId::from("default".to_string()),
            "https://unknown.example.com".to_string(),
        );
        assert!(matches!(response, Response::Error { .. }));
    }

    #[test]
    fn test_open_same_tenant_returns_local() {
        let mut state = CoordinatorState::new(test_config());
        let response = state.handle_open(
            TenantId::from("work".to_string()),
            "https://app.work.com".to_string(),
        );
        assert_eq!(response, Response::Local);
    }

    #[test]
    fn test_open_different_tenant_routes_remotely() {
        let mut state = CoordinatorState::new(test_config());
        let response = state.handle_open(
            TenantId::from("personal".to_string()),
            "https://app.work.com".to_string(),
        );
        assert_eq!(
            response,
            Response::Remote {
                tenant_id: TenantId::from("work".to_string())
            }
        );
    }

    #[test]
    fn test_cooldown_returns_local() {
        let mut state = CoordinatorState::new(test_config());

        // First open routes remotely
        let response = state.handle_open(
            TenantId::from("personal".to_string()),
            "https://app.work.com".to_string(),
        );
        assert!(matches!(response, Response::Remote { .. }));

        // Second open from the DESTINATION should be on cooldown
        let response = state.handle_open(
            TenantId::from("work".to_string()),
            "https://app.work.com".to_string(),
        );
        assert_eq!(response, Response::Local);
    }

    #[test]
    fn test_command_evaluates_rules() {
        let state = CoordinatorState::new(test_config());
        let response = state.handle_test("https://blog.personal.io/post");
        assert!(matches!(response, Response::Match { .. }));
    }

    #[test]
    fn test_command_no_match() {
        let state = CoordinatorState::new(test_config());
        let response = state.handle_test("https://unknown.com");
        assert_eq!(
            response,
            Response::NoMatch {
                default_tenant: TenantId::from("local".to_string())
            }
        );
    }

    #[test]
    fn test_get_config_returns_json() {
        let state = CoordinatorState::new(test_config());
        let response = state.handle_get_config();
        assert!(matches!(response, Response::Config { .. }));
    }

    #[test]
    fn test_status_returns_info() {
        let state = CoordinatorState::new(test_config());
        let response = state.handle_status();
        if let Response::Status { json } = response {
            let info: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert_eq!(info["rules"], 2);
            assert_eq!(info["tenants"], 2);
        } else {
            panic!("expected Status response");
        }
    }

    #[test]
    fn test_add_rule() {
        let mut state = CoordinatorState::new(test_config());
        let json = r#"{"pattern": ".*\\.test\\.org", "tenant": "work"}"#;
        assert_eq!(state.handle_add_rule(json), Response::Ok);
        assert_eq!(state.config.rules.len(), 3);
    }

    #[test]
    fn test_delete_rule() {
        let mut state = CoordinatorState::new(test_config());
        assert_eq!(state.config.rules.len(), 2);
        assert_eq!(state.handle_delete_rule(RuleIndex::from(0)), Response::Ok);
        assert_eq!(state.config.rules.len(), 1);
    }

    #[test]
    fn test_delete_rule_out_of_range() {
        let mut state = CoordinatorState::new(test_config());
        let response = state.handle_delete_rule(RuleIndex::from(99));
        assert!(matches!(response, Response::Error { .. }));
    }

    #[test]
    fn test_open_on_known_tenant() {
        let mut state = CoordinatorState::new(test_config());
        let response = state.handle_open_on(
            TenantId::from("work".to_string()),
            "https://any.com".to_string(),
        );
        assert_eq!(
            response,
            Response::Remote {
                tenant_id: TenantId::from("work".to_string())
            }
        );
    }

    #[test]
    fn test_open_on_unknown_tenant() {
        let mut state = CoordinatorState::new(test_config());
        let response = state.handle_open_on(
            TenantId::from("nonexistent".to_string()),
            "https://any.com".to_string(),
        );
        assert!(matches!(response, Response::Error { .. }));
    }
}
