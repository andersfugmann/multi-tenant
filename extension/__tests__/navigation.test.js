const {
  createMock,
  triggerNavigation,
  triggerPortMessage,
  triggerPortDisconnect,
} = require("./chrome_mock");

let mock;

beforeEach(() => {
  jest.resetModules();
  mock = createMock();
  global.chrome = mock.chrome;
  global.console.log = jest.fn();
  require("../main.bc.js");
});

afterEach(() => {
  delete global.chrome;
});

describe("navigation interception", () => {
  test("sends OPEN command for top-level navigation", () => {
    const port = mock.ports[0];
    // Clear calls from initial Register + Get_config
    port.postMessage.mockClear();
    triggerNavigation(mock.listeners, "https://example.com", 1, 0);

    expect(port.postMessage).toHaveBeenCalledTimes(1);
    const msg = port.postMessage.mock.calls[0][0];
    expect(msg).toEqual(["Open", { url: "https://example.com" }]);
  });

  test("ignores sub-frame navigations", () => {
    const port = mock.ports[0];
    port.postMessage.mockClear();
    triggerNavigation(mock.listeners, "https://example.com", 1, 1);

    expect(port.postMessage).not.toHaveBeenCalled();
  });

  test("ignores chrome:// URLs", () => {
    const port = mock.ports[0];
    port.postMessage.mockClear();
    triggerNavigation(mock.listeners, "chrome://settings", 1, 0);

    expect(port.postMessage).not.toHaveBeenCalled();
  });

  test("ignores about: URLs", () => {
    const port = mock.ports[0];
    port.postMessage.mockClear();
    triggerNavigation(mock.listeners, "about:blank", 1, 0);

    expect(port.postMessage).not.toHaveBeenCalled();
  });

  test("handles NAVIGATE push by opening a tab", () => {
    const port = mock.ports[0];
    const pushMsg = { Push: ["Navigate", { url: "https://pushed.example.com" }] };
    // ppx format: ["Push", ["Navigate", {url: ...}]]
    triggerPortMessage(port, ["Push", ["Navigate", { url: "https://pushed.example.com" }]]);

    expect(mock.chrome.tabs.create).toHaveBeenCalledWith({
      url: "https://pushed.example.com",
    });
  });

  test("does not send commands when disconnected", () => {
    const port = mock.ports[0];
    triggerPortDisconnect(port);

    triggerNavigation(mock.listeners, "https://example.com", 1, 0);
    // After disconnect, no messages should be sent
    // port.postMessage was called 0 times for navigation (only for Register maybe)
    const callsAfterDisconnect = port.postMessage.mock.calls.length;
    triggerNavigation(mock.listeners, "https://another.com", 2, 0);
    expect(port.postMessage.mock.calls.length).toBe(callsAfterDisconnect);
  });
});

describe("response handling", () => {
  test("processes Local response without creating tabs", () => {
    const port = mock.ports[0];
    triggerNavigation(mock.listeners, "https://example.com", 1, 0);

    // Simulate response: bridge sends back Response with Ok_unit (Local maps to Local in route_result)
    // ppx format for Wire.response: Response wraps the wire response
    triggerPortMessage(port, ["Response", ["Ok_route", { Local: [] }]]);

    // Should not create a tab for local routing
    expect(mock.chrome.tabs.create).not.toHaveBeenCalled();
  });
});
