const {
  createMock,
  sendPopupMessage,
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

describe("popup messages", () => {
  test("get_status returns disconnected after port disconnect", async () => {
    const { triggerPortDisconnect } = require("./chrome_mock");
    triggerPortDisconnect(mock.ports[0]);

    // Allow Lwt microtask to process
    await new Promise((resolve) => setTimeout(resolve, 0));

    const response = await sendPopupMessage(mock.listeners, {
      action: "get_status",
    });

    expect(response).toHaveProperty("connected", false);
  });

  test("unknown action returns error", async () => {
    const response = await sendPopupMessage(mock.listeners, {
      action: "nonexistent",
    });

    expect(response).toHaveProperty("error", "unknown action");
  });

  test("invalid message returns error", async () => {
    const response = await sendPopupMessage(mock.listeners, {
      foo: "bar",
    });

    expect(response).toHaveProperty("error", "invalid message");
  });

  test("reconnect attempts new connection", async () => {
    const { triggerPortDisconnect } = require("./chrome_mock");
    triggerPortDisconnect(mock.ports[0]);

    await new Promise((resolve) => setTimeout(resolve, 0));

    const response = await sendPopupMessage(mock.listeners, {
      action: "reconnect",
    });

    // Should have created a new port
    expect(mock.chrome.runtime.connectNative).toHaveBeenCalledTimes(2);
    expect(response).toHaveProperty("connected", true);
  });
});

describe("context menus", () => {
  test("creates context menus on install", () => {
    // onInstalled was triggered during module load
    mock.listeners.onInstalled.forEach((cb) => cb({ reason: "install" }));

    expect(mock.chrome.contextMenus.create).toHaveBeenCalledWith(
      expect.objectContaining({ id: "open_in" })
    );
    expect(mock.chrome.contextMenus.create).toHaveBeenCalledWith(
      expect.objectContaining({ id: "send_to" })
    );
  });
});
