/**
 * Typed wrapper for daemon communication via Chrome native messaging.
 *
 * All communication with the native messaging host goes through this module.
 * Handles port lifecycle, message sending, and response parsing.
 */

import {
  type DaemonCommand,
  type DaemonResponse,
  type Config,
  ConfigSchema,
  parseDaemonResponse,
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
 * resolved in order (the protocol is strictly request-response).
 */
export class DaemonClient {
  private port: chrome.runtime.Port | null = null;
  private queue: PendingRequest[] = [];
  private disconnectListeners: Array<() => void> = [];

  /** Connect to the native messaging host. */
  connect(): void {
    if (this.port) return;

    this.port = chrome.runtime.connectNative(NATIVE_HOST_NAME);

    this.port.onMessage.addListener((msg: unknown) => {
      const pending = this.queue.shift();
      if (pending) {
        try {
          const response = parseDaemonResponse(msg);
          pending.resolve(response);
        } catch (e) {
          pending.reject(
            new Error(`invalid daemon response: ${JSON.stringify(msg)}`)
          );
        }
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
