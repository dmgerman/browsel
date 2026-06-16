// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>
//
// background.js (Firefox MV2) — persistent background page entry.
//
// All routing logic lives in src/core.js.  Firefox MV2 has a real
// persistent background page: it loads at extension start, stays
// resident as long as the browser is running, and holds the
// WebSocket directly via src/ws-client.js.  No offscreen indirection,
// no alarms heartbeat, no idle window.
//
// One MV2/MV3 difference must be papered over before the shared code
// runs: the toolbar action API.  Chrome MV3 calls `browser.action.*`;
// Firefox MV2 calls `browser.browserAction.*`.  The shared core.js
// uses `api.action`, so we alias it here, once, at module load.  The
// alias is a side effect of evaluating this module; subsequent
// imports of core.js then resolve `api.action.setIcon` against the
// MV2 API.

if (typeof browser !== "undefined"
    && !browser.action
    && browser.browserAction) {
  browser.action = browser.browserAction;
}

import {
  initRouter,
  setWsStatus,
  dispatchIncomingEmacsRequest,
} from "./core.js";
import { startWebSocketClient } from "./ws-client.js";

const client = startWebSocketClient({
  clientName: "firefox",
  onStatus:   setWsStatus,
  onIncomingRequest: dispatchIncomingEmacsRequest,
});

initRouter({
  sendRequest: (name, payload) => client.sendRequest(name, payload),
  reconnect:   () => {
    client.reconnect();
    return { ok: true };
  },
  getStatus:   () => client.getStatus(),
});
