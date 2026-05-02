/**
 * Typed wrapper for daemon communication via Chrome native messaging.
 *
 * All communication with the native messaging host goes through this module.
 * Handles port lifecycle, message sending, response parsing, and unsolicited
 * NAVIGATE messages from the daemon.
 */

import {
  type DaemonCommand,
  type DaemonResponse,
  type DaemonMessage,
  type Config,
  ConfigSchema,
  parseDaemonMessage,
} from "./protocol.js";

const NATIVE_HOST_NAME = "com.url_router";

type PendingRequest = {
  readonly resolve: (response: DaemonResponse) => void;
  readonly reject: (error: Error) => void;
};

/**
 * Client for communicating with the url-router daemon via native messaging.
 *
 * Maintains a persistent native messaging port. Requests are queued and
 * resolved in order. Unsolicited NAVIGATE messages are routed to registered
 * listeners instead of the request queue.
 */
export class DaemonClient {
  private port: chrome.runtime.Port | null = null;
  private queue: PendingRequest[] = [];
  private disconnectListeners: Array<() => void> = [];
  private navigateListeners: Array<(url: string) => void> = [];

  /** Connect to the native messaging host. */
  connect(): void {
    if (this.port) return;

    this.port = chrome.runtime.connectNative(NATIVE_HOST_NAME);

    this.port.onMessage.addListener((msg: unknown) => {
      let message: DaemonMessage;
      try {
        message = parseDaemonMessage(msg);
      } catch {
        const pending = this.queue.shift();
        if (pending) {
          pending.reject(
            new Error(`invalid daemon message: ${JSON.stringify(msg)}`)
          );
        }
        return;
      }

      if (message.status === "NAVIGATE") {
        for (const listener of this.navigateListeners) {
          listener(message.url);
        }
        return;
      }

      const pending = this.queue.shift();
      if (pending) {
        pending.resolve(message);
      }
    });

    this.port.onDisconnect.addListener(() => {
      this.port = null;
      const error = new Error("native host disconnected");
      for (const pending of this.queue) {
        pending.reject(error);
      }
      this.queue = [];
      for (const listener of this.disconnectListeners) {
        listener();
      }
    });
  }

  /** Register a callback for when the port disconnects. */
  onDisconnect(listener: () => void): void {
    this.disconnectListeners.push(listener);
  }

  /** Register a callback for unsolicited NAVIGATE messages from the daemon. */
  onNavigate(listener: (url: string) => void): void {
    this.navigateListeners.push(listener);
  }

  /** Send a command and return the response. */
  private send(command: DaemonCommand): Promise<DaemonResponse> {
    return new Promise((resolve, reject) => {
      if (!this.port) {
        this.connect();
      }
      if (!this.port) {
        reject(new Error("failed to connect to native host"));
        return;
      }
      this.queue.push({ resolve, reject });
      this.port.postMessage(command);
    });
  }

  /** Send `open <url>` — routing decision only. */
  async open(url: string): Promise<DaemonResponse> {
    return this.send({ cmd: "open", url });
  }

  /** Send `open-on <tenant> <url>` — explicit routing. */
  async openOn(tenant: string, url: string): Promise<DaemonResponse> {
    return this.send({ cmd: "open-on", tenant, url });
  }

  /** Send `add-rule` — persist a new routing rule. */
  async addRule(pattern: string, tenant: string): Promise<DaemonResponse> {
    return this.send({ cmd: "add-rule", rule: { pattern, tenant } });
  }

  /** Send `set-config` — replace the entire configuration. */
  async setConfig(config: Config): Promise<DaemonResponse> {
    return this.send({ cmd: "set-config", config });
  }

  /** Send `test <url>` — dry-run routing check. */
  async test(url: string): Promise<DaemonResponse> {
    return this.send({ cmd: "test", url });
  }

  /** Send `get-config` and parse the config data. */
  async getConfig(): Promise<Config> {
    const response = await this.send({ cmd: "get-config" });
    if (response.status !== "CONFIG") {
      throw new Error(`expected CONFIG response, got: ${response.status}`);
    }
    return ConfigSchema.parse(response.data);
  }

  /** Send `status`. */
  async getStatus(): Promise<DaemonResponse> {
    return this.send({ cmd: "status" });
  }

  /** Disconnect the native messaging port. */
  disconnect(): void {
    if (this.port) {
      this.port.disconnect();
      this.port = null;
    }
  }
}
