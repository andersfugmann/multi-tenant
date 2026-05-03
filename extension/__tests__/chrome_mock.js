// Chrome API mock for testing the compiled extension.
// Captures event listeners so tests can trigger events programmatically.

function createMock() {
  const listeners = {
    onBeforeNavigate: [],
    onContextMenuClicked: [],
    onInstalled: [],
    onStartup: [],
    onMessage: [],
  };

  const ports = [];

  function createPort() {
    const port = {
      postMessage: jest.fn(),
      onMessage: { addListener: jest.fn() },
      onDisconnect: { addListener: jest.fn() },
    };
    ports.push(port);
    return port;
  }

  const chrome = {
    runtime: {
      connectNative: jest.fn(() => createPort()),
      onInstalled: {
        addListener: jest.fn((cb) => listeners.onInstalled.push(cb)),
      },
      onStartup: {
        addListener: jest.fn((cb) => listeners.onStartup.push(cb)),
      },
      onMessage: {
        addListener: jest.fn((cb) => listeners.onMessage.push(cb)),
      },
    },
    tabs: {
      create: jest.fn(),
      remove: jest.fn(),
      query: jest.fn((_query, cb) => cb([{ url: "https://example.com", id: 1 }])),
    },
    storage: {
      local: {
        get: jest.fn((_keys, cb) => cb({})),
        set: jest.fn((_items, cb) => { if (cb) cb(); }),
      },
    },
    webNavigation: {
      onBeforeNavigate: {
        addListener: jest.fn((cb) => listeners.onBeforeNavigate.push(cb)),
      },
    },
    contextMenus: {
      create: jest.fn(),
      removeAll: jest.fn((cb) => { if (cb) cb(); }),
      onClicked: {
        addListener: jest.fn((cb) => listeners.onContextMenuClicked.push(cb)),
      },
    },
  };

  return { chrome, listeners, ports };
}

// Simulate a navigation event
function triggerNavigation(listeners, url, tabId, frameId) {
  listeners.onBeforeNavigate.forEach((cb) =>
    cb({ url, tabId, frameId })
  );
}

// Simulate a native port message arriving
function triggerPortMessage(port, msg) {
  port.onMessage.addListener.mock.calls.forEach(([cb]) =>
    cb(msg)
  );
}

// Simulate port disconnect
function triggerPortDisconnect(port) {
  port.onDisconnect.addListener.mock.calls.forEach(([cb]) => cb());
}

// Send a popup message and capture the response
function sendPopupMessage(listeners, message) {
  return new Promise((resolve) => {
    listeners.onMessage.forEach((cb) => {
      cb(message, {}, resolve);
    });
  });
}

module.exports = {
  createMock,
  triggerNavigation,
  triggerPortMessage,
  triggerPortDisconnect,
  sendPopupMessage,
};
