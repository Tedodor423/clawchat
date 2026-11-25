#!/usr/bin/env node
// clawchat bridge: one long-lived connection to an OpenClaw gateway for the quick-chat overlay.
// Started by Service.qml; talks JSON lines on stdin/stdout.
//
//   stdin  {"cmd":"send","text":"...","id":"<uuid>"}   send a message into the agent's session
//          {"cmd":"refresh"}                           fetch history now
//          {"cmd":"visible","on":true|false}           overlay shown/hidden (poll faster while shown)
//   stdout {"t":"config","agentName":string,"keyLabel":string}
//          {"t":"conn","ok":bool,"error"?:string,"sessionKey"?:string}
//          {"t":"history","messages":[{id,role,text,ts}],"running":bool,"inflight":string}
//          {"t":"delta","runId":string,"text":string}  reply so far for a running turn
//          {"t":"final","runId":string,"state":"final"|"aborted"|"error","error"?:string}
//          {"t":"sent","id":string,"ok":bool,"runId"?:string,"error"?:string}
//
// Run by hand:
//   clawchat-bridge.mjs pair      pair this device with the gateway (needs the shared gateway token
//                                 once, from $OPENCLAW_GATEWAY_TOKEN or the env file; never stored)
//   clawchat-bridge.mjs whoami    device id and whether a device token is stored
//
// The device has its own Ed25519 identity and asks only for operator.read + operator.write.
// State (mode 600): ~/.local/state/omarchy/theo.clawchat/openclaw/{device.json,device-token.json}
// Settings: ~/.local/state/omarchy/theo.clawchat/config.json (see README). Nothing secret is printed.
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

const HOME = os.homedir();
const STATE = process.env.CLAWCHAT_STATE || path.join(HOME, ".local/state/omarchy/theo.clawchat");
const LIB = process.env.CLAWCHAT_GATEWAY_CLIENT ||
  path.join(HOME, ".local/share/theo.clawchat/bridge/node_modules/@openclaw/gateway-client/dist/index.mjs");
const SCOPES = ["operator.read", "operator.write"];
const ROLE = "operator";

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}
function writePrivate(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
}
function readEnvFile() {
  const out = {};
  if (!cfg.envFile) return out;
  try {
    for (const line of fs.readFileSync(String(cfg.envFile).replace(/^~(?=\/)/, HOME), "utf8").split("\n")) {
      const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
      if (m) out[m[1]] = m[2].trim();
    }
  } catch {}
  return out;
}

// config.json (all optional), see README.
const cfg = Object.assign({
  gatewayUrl: "",        // wss://host...; else $OPENCLAW_GATEWAY_URL, else OPENCLAW_GATEWAY_URL in envFile
  envFile: "",           // a KEY=value file that may hold OPENCLAW_GATEWAY_URL / OPENCLAW_GATEWAY_TOKEN
  agentName: "OpenClaw", // title of the window
  agentId: "main",
  channel: "telegram",   // join the newest direct session of this channel; "" = the agent's main session
  sessionKey: "",        // or name the session outright
  deliver: false,        // also post replies into that channel's chat
  historyLimit: 30,
  keyLabel: "F8",
}, readJson(path.join(STATE, "config.json")) || {});
function gatewayUrl() { return cfg.gatewayUrl || process.env.OPENCLAW_GATEWAY_URL || readEnvFile().OPENCLAW_GATEWAY_URL || ""; }

function emit(obj) { process.stdout.write(JSON.stringify(obj) + "\n"); }
function redact(s) { return String(s).replace(/[A-Za-z0-9_-]{40,}/g, "<redacted>").slice(0, 300); }
function errMsg(e) { return redact(e?.message || e); }

// ---------------------------------------------------------------- device identity
const identityFile = path.join(STATE, "openclaw/device.json");
const tokenFile = path.join(STATE, "openclaw/device-token.json");
let identity = readJson(identityFile);
function rawPublicKey(pem) {
  const der = crypto.createPublicKey(pem).export({ type: "spki", format: "der" });
  return der.subarray(der.length - 32);
}
function createIdentity() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" }).toString();
  const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  // Same derivation as OpenClaw: id = sha256(raw ed25519 public key)
  const deviceId = crypto.createHash("sha256").update(rawPublicKey(publicKeyPem)).digest("hex");
  identity = { deviceId, publicKeyPem, privateKeyPem, createdAt: new Date().toISOString() };
  writePrivate(identityFile, identity);
}
function clientOptions(url) {
  return {
    url, role: ROLE, scopes: SCOPES, clientName: "gateway-client", mode: "backend",
    clientDisplayName: `clawchat (${os.hostname()})`, clientVersion: "clawchat-0.1", platform: "linux",
    deviceIdentity: { deviceId: identity.deviceId, publicKeyPem: identity.publicKeyPem, privateKeyPem: identity.privateKeyPem },
    hostDeps,
  };
}
const hostDeps = {
  loadOrCreateDeviceIdentity: () => identity,
  signDevicePayload: (privateKeyPem, payload) =>
    crypto.sign(null, Buffer.from(payload, "utf8"), crypto.createPrivateKey(privateKeyPem)).toString("base64url"),
  publicKeyRawBase64UrlFromPem: (pem) => rawPublicKey(pem).toString("base64url"),
  loadDeviceAuthToken: ({ deviceId, role }) => {
    const t = readJson(tokenFile);
    return t && t.deviceId === deviceId && t.role === role && t.token ? { token: t.token, scopes: t.scopes || [] } : null;
  },
  storeDeviceAuthToken: ({ deviceId, role, token, scopes }) =>
    writePrivate(tokenFile, { deviceId, role, token, scopes, storedAt: new Date().toISOString() }),
  clearDeviceAuthToken: () => {},   // never throw the pairing away on a transient failure
  logDebug: () => {},
  logError: () => {},
};

// ---------------------------------------------------------------- messages
function contentText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((p) => p && p.type === "text" && typeof p.text === "string").map((p) => p.text).join("\n\n");
}
function normalize(m, idx) {
  if (!m || typeof m !== "object") return null;
  const role = m.role === "user" ? "user" : m.role === "assistant" ? "assistant" : null;
  if (!role) return null;
  let text = contentText(m.content).trim();
  if (!text) return null;                                   // tool calls / results
  if (role === "user") {
    if (/^\[OpenClaw:/.test(text) || /^\[OpenClaw heartbeat/.test(text)) return null;   // gateway bookkeeping
    const voice = text.match(/^\[Audio transcript[^\]]*\]:\s*"([\s\S]*)"$/);
    if (voice) text = "🎙 " + voice[1];
  }
  const oc = m.__openclaw || {};
  return { id: String(oc.id || oc.seq || `${m.timestamp || 0}-${idx}`), role, text, ts: Number(m.timestamp) || 0 };
}

// ---------------------------------------------------------------- gateway
let client = null;
let connected = false;
let sessionKey = cfg.sessionKey || "";
let visible = false;
let running = false;            // a turn is in flight (ours or one started from Telegram)
let lastHistorySig = "";
let historyBusy = false;
let historyAgain = false;
const streams = new Map();      // runId -> text so far

async function discoverSession() {
  if (sessionKey) return;
  try {
    const res = await client.request("sessions.list", { limit: 200 }, { timeoutMs: 15000 });
    const prefix = `agent:${cfg.agentId}:${cfg.channel}:direct:`;
    const direct = !cfg.channel ? [] : (res?.sessions || [])
      .filter((s) => s.channel === cfg.channel && String(s.key || "").startsWith(prefix))
      .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
    sessionKey = direct[0]?.key || `agent:${cfg.agentId}:main`;
  } catch {
    sessionKey = `agent:${cfg.agentId}:main`;
  }
}

async function fetchHistory(force) {
  if (!sessionKey) return;
  if (!connected) return;
  if (historyBusy) { historyAgain = true; return; }
  historyBusy = true;
  try {
    const want = Math.max(5, Math.min(200, Number(cfg.historyLimit) || 30));
    const res = await client.request("chat.history", { sessionKey, limit: want * 3 }, { timeoutMs: 15000 });
    const messages = (res?.messages || []).map(normalize).filter(Boolean).slice(-want);
    const active = !!(res?.sessionInfo?.hasActiveRun || res?.inFlightRun);
    const inflight = typeof res?.inFlightRun?.text === "string" ? res.inFlightRun.text : "";
    running = active;
    if (!active) streams.clear();
    const sig = JSON.stringify([messages.length, messages.at(-1)?.id, messages.at(-1)?.text.length, active, inflight.length]);
    if (force || sig !== lastHistorySig) {
      lastHistorySig = sig;
      emit({ t: "history", messages, running: active, inflight });
    }
  } catch (e) {
    emit({ t: "conn", ok: connected, error: "history: " + errMsg(e) });
  } finally {
    historyBusy = false;
    if (historyAgain) { historyAgain = false; setTimeout(() => fetchHistory(false), 150); }
  }
}

let refetchTimer = null;
function refetchSoon(ms = 300) {
  clearTimeout(refetchTimer);
  refetchTimer = setTimeout(() => fetchHistory(false), ms);
}

function onEvent(frame) {
  const name = frame?.event;
  const p = frame?.payload;
  if (!p || typeof p !== "object") return;
  if (name === "chat" && p.sessionKey === sessionKey) {
    const runId = String(p.runId || "");
    if (p.state === "delta") {
      running = true;
      const full = contentText(p.message?.content);
      const prev = streams.get(runId) || "";
      const text = full || (p.replace ? p.deltaText : prev + (p.deltaText || "")) || prev;
      streams.set(runId, text);
      emit({ t: "delta", runId, text });
    } else if (p.state === "final" || p.state === "aborted" || p.state === "error") {
      streams.delete(runId);
      emit({ t: "final", runId, state: p.state, error: p.state === "final" ? undefined : redact(p.errorMessage || p.error?.message || p.state) });
      fetchHistory(true);
    } else if (p.state === "status") {
      running = true;
    }
    return;
  }
  // Anything else about our session (a Telegram message arriving, a run starting elsewhere).
  const key = p.sessionKey || p.key || p.session?.key;
  if (key === sessionKey) refetchSoon();
}

async function onHello() {
  connected = true;
  await discoverSession();
  emit({ t: "conn", ok: true, sessionKey });
  // Live updates for messages that arrive from Telegram; without it the poll below still catches them.
  client.request("sessions.messages.subscribe", { subscriptionId: crypto.randomUUID(), key: sessionKey }, { timeoutMs: 10000 }).catch(() => {});
  fetchHistory(true);
}

async function send(text, id) {
  if (!connected) { emit({ t: "sent", id, ok: false, error: "not connected" }); return; }
  const params = { sessionKey, message: text, idempotencyKey: id || crypto.randomUUID() };
  if (cfg.deliver) params.deliver = true;      // also post the reply into the channel's chat
  try {
    const res = await client.request("chat.send", params, { timeoutMs: 30000 });
    running = true;
    emit({ t: "sent", id, ok: true, runId: res?.runId || "" });
    refetchSoon(400);
  } catch (e) {
    emit({ t: "sent", id, ok: false, error: errMsg(e) });
  }
}

// One-off connection with the shared gateway token: the gateway registers the device and hands back
// a device token, which hostDeps stores. Later connections use only that.
async function pair() {
  const url = gatewayUrl();
  if (!url) { console.log(JSON.stringify({ paired: false, message: "no gateway URL: set gatewayUrl in config.json or OPENCLAW_GATEWAY_URL" })); return 2; }
  const shared = process.env.OPENCLAW_GATEWAY_TOKEN || readEnvFile().OPENCLAW_GATEWAY_TOKEN;
  if (!shared) { console.log(JSON.stringify({ paired: false, message: "no shared gateway token: run with OPENCLAW_GATEWAY_TOKEN=... (needed only to pair)" })); return 2; }
  if (!identity?.deviceId) createIdentity();
  const { GatewayClient } = await import(pathToFileURL(LIB).href);
  let c;
  try {
    const hello = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("connect timed out")), 20000);
      const done = (fn, v) => { clearTimeout(timer); fn(v); };
      c = new GatewayClient({
        ...clientOptions(url), token: shared,
        onHelloOk: (h) => done(resolve, h),
        onConnectError: (e) => done(reject, e),
        onReconnectPaused: (info) => done(reject, new Error(`${info?.detailCode || "paused"}: ${info?.reason || ""}`)),
        onClose: (code, reason) => done(reject, new Error(`closed ${code} ${reason || ""}`.trim())),
      });
      c.start();
    });
    console.log(JSON.stringify({ paired: true, deviceId: identity.deviceId, scopes: hello?.auth?.scopes || null, deviceTokenStored: !!readJson(tokenFile)?.token }));
    return 0;
  } catch (e) {
    console.log(JSON.stringify({ paired: false, deviceId: identity.deviceId, message: errMsg(e) }));
    return 2;
  } finally {
    try { c?.stop(); } catch {}
  }
}

async function main() {
  emit({ t: "config", agentName: String(cfg.agentName || "OpenClaw"), keyLabel: String(cfg.keyLabel || "F8") });
  if (!identity?.deviceId || !identity.privateKeyPem || !readJson(tokenFile)?.token) {
    emit({ t: "conn", ok: false, error: "this device is not paired yet: run the plugin's install.sh, or bridge/clawchat-bridge.mjs pair" });
    setTimeout(() => process.exit(3), 100);
    return;
  }
  const url = gatewayUrl();
  if (!url) {
    emit({ t: "conn", ok: false, error: "no gateway URL: set gatewayUrl in config.json" });
    setTimeout(() => process.exit(3), 100);
    return;
  }
  const { GatewayClient } = await import(pathToFileURL(LIB).href);
  const fail = (error) => { connected = false; emit({ t: "conn", ok: false, error }); };
  client = new GatewayClient({
    ...clientOptions(url),
    onHelloOk: () => { onHello().catch((e) => fail(errMsg(e))); },
    onEvent,
    onConnectError: (e) => fail(errMsg(e)),
    onClose: (code, reason) => fail(`connection closed${reason ? ": " + redact(reason) : ""}`),
    // The client stopped retrying: exit so the service restarts us after a pause.
    onReconnectPaused: (info) => { fail(redact(info?.reason || "reconnect paused")); setTimeout(() => process.exit(2), 100); },
  });
  client.start();

  // Fallback poll: quick while a turn runs, slow while the overlay is just open, off when hidden.
  setInterval(() => {
    if (!connected) return;
    const now = Date.now();
    const every = running ? 1500 : visible ? 6000 : 0;
    if (every && now - lastPoll >= every) { lastPoll = now; fetchHistory(false); }
  }, 500);

  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.cmd === "send" && typeof msg.text === "string" && msg.text.trim()) send(msg.text.trim(), msg.id);
    else if (msg.cmd === "refresh") fetchHistory(true);
    else if (msg.cmd === "visible") { visible = !!msg.on; if (visible) fetchHistory(true); }
  });
  rl.on("close", () => { try { client.stop(); } catch {} process.exit(0); });   // the shell went away
}
let lastPoll = 0;

const mode = process.argv[2];
if (mode === "pair") {
  pair().then((code) => process.exit(code), (e) => { console.error(errMsg(e)); process.exit(1); });
} else if (mode === "whoami") {
  console.log(JSON.stringify({ deviceId: identity?.deviceId || null, deviceToken: !!readJson(tokenFile)?.token, gatewayUrl: !!gatewayUrl(), requested: SCOPES }));
} else {
  main().catch((e) => { emit({ t: "conn", ok: false, error: errMsg(e) }); process.exit(1); });
}
