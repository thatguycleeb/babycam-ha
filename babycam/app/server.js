'use strict';
// BabyCam relay: the camera page streams JPEG frames + PCM audio over a WebSocket,
// and this server fans them out to viewers, HA's MJPEG camera, and noise sensors.
//
// Wire format (same as the iPhone app):
//   binary: first byte 1 = JPEG frame, 2 = 16 kHz mono Int16 LE PCM
//   text:   JSON. Camera sends {type:"status",...}; viewers send {cmd:"swap"|"torch"|"night"|"rotate", value?}
//           Server sends {type:"camera", online} to viewers and {type:"viewers", count} to the camera.

const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const os = require('os');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');
const { ensureCertificate, cloudflare } = require('./certs');
const HomeAssistant = require('./ha');
const TsStream = require('./stream');

const DEV = process.env.BABYCAM_DEV === '1';
const DATA_DIR = process.env.BABYCAM_DATA || (DEV ? path.join(__dirname, 'dev-data') : '/data');
const PUBLIC_DIR = path.join(__dirname, 'public');
const INGRESS_PORT = Number(process.env.BABYCAM_INGRESS_PORT) || 8099;
const LOCAL_PORT = Number(process.env.BABYCAM_LOCAL_PORT) || 8098;
const INGRESS_PROXY = new Set(['172.30.32.2', '::ffff:172.30.32.2']);
const MAX_VIDEO_BACKLOG = 512 * 1024;
const MAX_AUDIO_BACKLOG = 1024 * 1024;
const COMMANDS = new Set(['swap', 'torch', 'night', 'rotate']);

const log = (...args) => console.log(new Date().toISOString().slice(11, 19), ...args);

fs.mkdirSync(DATA_DIR, { recursive: true });
const options = loadOptions();
const accessCode = loadAccessCode();
const ha = new HomeAssistant(log);
const tsStream = new TsStream(log);
tsStream.onClientsChange = () => sendViewerCount();

// ---------------------------------------------------------------------------
// Options

function loadOptions() {
  const defaults = {
    domain: '', email: '', cloudflare_api_token: '', access_code: '',
    port: 8443, noise_threshold_db: -35, create_dns_record: true, lan_ip: '',
  };
  try {
    return { ...defaults, ...JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'options.json'), 'utf8')) };
  } catch {
    return defaults;
  }
}

function loadAccessCode() {
  const configured = String(options.access_code || '').replace(/\D/g, '');
  if (configured.length >= 4) return configured;
  if (options.access_code) log('access_code must be 4–8 digits; generating one instead.');
  const file = path.join(DATA_DIR, 'access_code');
  try {
    const saved = fs.readFileSync(file, 'utf8').trim();
    if (saved) return saved;
  } catch {}
  const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
  fs.writeFileSync(file, code);
  return code;
}

function publicBase() {
  if (DEV) return `http://localhost:${options.port}`;
  return `https://${options.domain}${Number(options.port) === 443 ? '' : ':' + options.port}`;
}

// ---------------------------------------------------------------------------
// Auth helpers (direct URL needs the access code; ingress is already behind HA login)

const failures = new Map();   // ip -> { count, until }

function isBlocked(ip) {
  const f = failures.get(ip);
  return !!f && f.until > Date.now();
}

function authFailed(ip) {
  const now = Date.now();
  const f = failures.get(ip);
  const entry = !f || f.until < now - 10 * 60 * 1000 ? { count: 0, until: 0 } : f;
  entry.count += 1;
  if (entry.count >= 10) {
    entry.until = now + 10 * 60 * 1000;
    entry.count = 0;
    log(`Too many wrong access codes from ${ip}; blocking for 10 minutes.`);
  }
  failures.set(ip, entry);
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function isIngressProxy(req) {
  return DEV || INGRESS_PROXY.has(req.socket.remoteAddress);
}

function basicAuthOk(req) {
  const ip = req.socket.remoteAddress;
  if (isBlocked(ip)) return false;
  const header = req.headers.authorization || '';
  if (header.startsWith('Basic ')) {
    const decoded = Buffer.from(header.slice(6), 'base64').toString();
    const password = decoded.slice(decoded.indexOf(':') + 1);
    if (safeEqual(password, accessCode)) return true;
    authFailed(ip);
  }
  return false;
}

// ---------------------------------------------------------------------------
// HTTP

function send(res, status, type, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', ...headers });
  res.end(body);
}

function page(name, config) {
  const html = fs.readFileSync(path.join(PUBLIC_DIR, name), 'utf8');
  return html.replace('<!--BABYCAM_CONFIG-->',
    `<script>window.BABYCAM_CONFIG = ${JSON.stringify(config)};</script>`);
}

function handleRequest(req, res, ingress) {
  if (ingress && !isIngressProxy(req)) return send(res, 403, 'text/plain', 'Forbidden');
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'text/plain', 'Method not allowed');

  const { pathname } = new URL(req.url, 'http://localhost');
  const cameraUrl = options.domain || DEV ? `${publicBase()}/camera` : null;
  const needAuth = () => {
    send(res, 401, 'text/plain', 'Access code required', { 'WWW-Authenticate': 'Basic realm="BabyCam"' });
  };

  switch (pathname) {
    case '/':
    case '/index.html':
      return send(res, 200, 'text/html; charset=utf-8', page('viewer.html', { ingress, cameraUrl }));
    case '/camera':
      return send(res, 200, 'text/html; charset=utf-8', page('camera.html', { ingress }));
    case '/snapshot.jpg':
    case '/mjpeg':
    case '/stream.ts':
    case '/health':
      if (!ingress && !basicAuthOk(req)) return needAuth();
      return serveMedia(pathname, req, res);
    default:
      return send(res, 404, 'text/plain', 'Not found');
  }
}

// Plain HTTP on 127.0.0.1 only, for Home Assistant itself (Generic Camera, go2rtc,
// HomeKit all run on this machine). Nothing else on the network can reach it,
// so it needs no access code or certificate.
function handleLocalRequest(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'text/plain', 'Method not allowed');
  const { pathname } = new URL(req.url, 'http://localhost');
  if (['/snapshot.jpg', '/mjpeg', '/stream.ts', '/health'].includes(pathname)) {
    return serveMedia(pathname, req, res);
  }
  return send(res, 404, 'text/plain', 'Not found');
}

function serveMedia(pathname, req, res) {
  switch (pathname) {
    case '/snapshot.jpg': {
      // A blank frame while the phone is offline, so HA shows "offline" rather than an error.
      const frame = hub.lastFrame || tsStream.placeholder;
      if (!frame) return send(res, 503, 'text/plain', 'No frame yet');
      return send(res, 200, 'image/jpeg', frame);
    }
    case '/mjpeg':
      return startMjpeg(req, res);
    case '/stream.ts':
      if (!tsStream.available) return send(res, 503, 'text/plain', 'ffmpeg is not available');
      return tsStream.addClient(req, res);
    default:
      return send(res, 200, 'application/json', JSON.stringify({
        camera: !!hub.camera, viewers: hub.viewers.size, mjpeg: hub.mjpeg.size, stream: tsStream.clients.size,
      }));
  }
}

// ---------------------------------------------------------------------------
// WebSockets

const wss = new WebSocketServer({
  noServer: true,
  maxPayload: 4 * 1024 * 1024,
  perMessageDeflate: false,
  // Echo back the code subprotocol (already checked in handleUpgrade) or browsers drop the connection.
  handleProtocols: (protocols) => {
    for (const p of protocols) if (p.startsWith('code-')) return p;
    return false;
  },
});

function rejectUpgrade(socket, status) {
  socket.end(`HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\nConnection: close\r\n\r\n`);
}

function handleUpgrade(req, socket, head, ingress) {
  socket.on('error', () => {});
  const { pathname } = new URL(req.url, 'http://localhost');
  const role = pathname === '/ws/camera' ? 'camera' : pathname === '/ws/view' ? 'viewer' : null;
  if (!role) return rejectUpgrade(socket, 404);

  if (ingress) {
    if (!isIngressProxy(req)) return rejectUpgrade(socket, 403);
  } else {
    const ip = req.socket.remoteAddress;
    if (isBlocked(ip)) return rejectUpgrade(socket, 429);
    const offered = String(req.headers['sec-websocket-protocol'] || '').split(',').map((s) => s.trim());
    if (!offered.some((p) => safeEqual(p, 'code-' + accessCode))) {
      authFailed(ip);
      return rejectUpgrade(socket, 401);
    }
  }

  wss.handleUpgrade(req, socket, head, (ws) => (role === 'camera' ? onCamera(ws) : onViewer(ws)));
}

function heartbeat(ws) {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
}

setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false;
    ws.ping();
  }
}, 15000);

// ---------------------------------------------------------------------------
// Hub

const hub = {
  camera: null,
  viewers: new Set(),
  mjpeg: new Set(),
  status: null,      // latest status JSON string from the camera
  lastFrame: null,   // latest JPEG Buffer
};

function broadcastText(obj) {
  const text = typeof obj === 'string' ? obj : JSON.stringify(obj);
  for (const v of hub.viewers) v.send(text);
}

function sendViewerCount() {
  const count = hub.viewers.size + hub.mjpeg.size + tsStream.clients.size;
  if (hub.camera) hub.camera.send(JSON.stringify({ type: 'viewers', count }));
}

function onCamera(ws) {
  if (hub.camera) hub.camera.close(4000, 'Another camera connected');
  hub.camera = ws;
  heartbeat(ws);
  log('Camera connected');
  ha.setCamera(true);
  tsStream.setCameraOnline(true);
  broadcastText({ type: 'camera', online: true });
  sendViewerCount();

  ws.on('message', (data, isBinary) => {
    if (hub.camera !== ws) return;
    if (isBinary) onCameraPacket(Buffer.isBuffer(data) ? data : Buffer.concat(data));
    else onCameraText(data.toString());
  });
  ws.on('close', () => {
    if (hub.camera !== ws) return;
    hub.camera = null;
    log('Camera disconnected');
    ha.setCamera(false);
    tsStream.setCameraOnline(false);
    noise.reset();
    broadcastText({ type: 'camera', online: false });
  });
}

function onCameraPacket(buf) {
  if (buf.length < 2) return;
  if (buf[0] === 1) {
    hub.lastFrame = buf.subarray(1);
    for (const v of hub.viewers) if (v.bufferedAmount < MAX_VIDEO_BACKLOG) v.send(buf);
    for (const res of hub.mjpeg) if (res.writableLength < MAX_VIDEO_BACKLOG) writeMjpegPart(res, hub.lastFrame);
    tsStream.pushFrame(hub.lastFrame);
  } else if (buf[0] === 2) {
    for (const v of hub.viewers) if (v.bufferedAmount < MAX_AUDIO_BACKLOG) v.send(buf);
    noise.process(buf.subarray(1));
    tsStream.pushAudio(buf.subarray(1));
  }
}

function onCameraText(text) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }
  if (msg && msg.type === 'status') {
    hub.status = text;
    broadcastText(text);
  }
}

function onViewer(ws) {
  hub.viewers.add(ws);
  heartbeat(ws);
  sendViewerCount();
  ws.send(JSON.stringify({ type: 'camera', online: !!hub.camera }));
  if (hub.camera && hub.status) ws.send(hub.status);
  if (hub.camera && hub.lastFrame) ws.send(Buffer.concat([Buffer.from([1]), hub.lastFrame]));

  ws.on('message', (data, isBinary) => {
    if (isBinary || !hub.camera) return;
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { return; }
    if (!msg || !COMMANDS.has(msg.cmd)) return;
    const cmd = { cmd: msg.cmd };
    if (typeof msg.value === 'boolean') cmd.value = msg.value;
    hub.camera.send(JSON.stringify(cmd));
  });
  ws.on('close', () => {
    hub.viewers.delete(ws);
    sendViewerCount();
  });
}

// ---------------------------------------------------------------------------
// MJPEG for Home Assistant's "MJPEG IP Camera" integration

function writeMjpegPart(res, jpeg) {
  res.write(`--babycamframe\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n`);
  res.write(jpeg);
  res.write('\r\n');
}

function startMjpeg(req, res) {
  res.writeHead(200, {
    'Content-Type': 'multipart/x-mixed-replace; boundary=babycamframe',
    'Cache-Control': 'no-store',
    Connection: 'close',
  });
  hub.mjpeg.add(res);
  sendViewerCount();
  if (hub.lastFrame) writeMjpegPart(res, hub.lastFrame);
  req.on('close', () => {
    hub.mjpeg.delete(res);
    sendViewerCount();
  });
}

// ---------------------------------------------------------------------------
// Noise detection (runs on the server, so alerts work even when nobody is watching)

const noise = {
  streak: 0,
  active: false,
  lastLoud: 0,
  peak: -90,

  process(pcm) {
    const n = pcm.length >> 1;
    if (!n) return;
    let sum = 0;
    for (let i = 0; i < n; i++) {
      const v = pcm.readInt16LE(i * 2) / 32768;
      sum += v * v;
    }
    const db = Math.max(-90, 20 * Math.log10(Math.sqrt(sum / n) || 1e-9));
    this.peak = Math.max(this.peak, db);

    // ~0.25 s over the threshold turns it on; 10 s of quiet turns it off.
    this.streak = db > options.noise_threshold_db ? this.streak + 1 : 0;
    const now = Date.now();
    if (this.streak >= 3) {
      this.lastLoud = now;
      if (!this.active) {
        this.active = true;
        log(`Noise detected (${db.toFixed(0)} dB)`);
        ha.setNoise(true);
      }
    } else if (this.active && now - this.lastLoud > 10000) {
      this.active = false;
      ha.setNoise(false);
    }
  },

  reset() {
    this.streak = 0;
    this.peak = -90;
    if (this.active) {
      this.active = false;
      ha.setNoise(false);
    }
  },
};

// Loudest level in each 5 s window -> sensor.babycam_sound_level
setInterval(() => {
  ha.setLevel(hub.camera ? Math.round(noise.peak) : null);
  noise.peak = -90;
}, 5000);

// ---------------------------------------------------------------------------
// Startup

function detectLanIp() {
  const skip = /^(docker|hassio|veth|br-|lo)/;
  const found = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    if (skip.test(name)) continue;
    for (const a of addrs || []) {
      const v4 = a.family === 'IPv4' || a.family === 4;
      if (v4 && !a.internal && !a.address.startsWith('172.30.')) found.push(a.address);
    }
  }
  return found.find((ip) => ip.startsWith('192.168.')) || found.find((ip) => ip.startsWith('10.')) || found[0] || '';
}

function announce() {
  const base = publicBase();
  log('──────────────────────────────────────────────');
  log(`Camera phone:  ${base}/camera`);
  log(`Viewer:        ${base}/`);
  log(`Access code:   ${accessCode}`);
  log(`Other devices: ${base}/stream.ts and ${base}/snapshot.jpg (username "babycam", password = access code)`);
  log('──────────────────────────────────────────────');
}

function listen(server, ingress, port, onReady) {
  server.on('upgrade', (req, socket, head) => handleUpgrade(req, socket, head, ingress));
  server.on('error', (e) => log(`Server error on port ${port}: ${e.message}`));
  server.listen(port, onReady);
}

async function startHttps() {
  const { domain, email, cloudflare_api_token: token } = options;
  if (!domain || !email || !token) {
    log('Set domain, email and cloudflare_api_token in the Configuration tab, then restart.');
    log('Until then only the Home Assistant sidebar viewer works (and there is no camera page).');
    return;
  }

  let creds;
  try {
    creds = await ensureCertificate({ domain, email, token, dataDir: DATA_DIR, log });
  } catch (e) {
    log(`Certificate error: ${e.message}`);
    log('Retrying in 15 minutes…');
    setTimeout(startHttps, 15 * 60 * 1000);
    return;
  }

  if (options.create_dns_record) {
    const ip = options.lan_ip || detectLanIp();
    if (!ip) {
      log('Could not detect this machine\'s LAN IP. Set lan_ip in the Configuration tab.');
    } else {
      try {
        await cloudflare(token).upsertLocalRecord(domain, ip, log);
      } catch (e) {
        log(`DNS record error: ${e.message}`);
      }
    }
  }

  const server = https.createServer({ key: creds.key, cert: creds.cert }, (req, res) => handleRequest(req, res, false));
  listen(server, false, options.port, announce);

  setInterval(async () => {
    try {
      const fresh = await ensureCertificate({ domain, email, token, dataDir: DATA_DIR, log });
      if (fresh.renewed) server.setSecureContext({ key: fresh.key, cert: fresh.cert });
    } catch (e) {
      log(`Certificate renewal failed: ${e.message}`);
    }
  }, 12 * 60 * 60 * 1000);
}

async function main() {
  log(`BabyCam starting${DEV ? ' (dev mode)' : ''}`);
  if (!ha.enabled) log('Home Assistant API not available; sensors disabled.');

  const ingressServer = http.createServer((req, res) => handleRequest(req, res, true));
  listen(ingressServer, true, INGRESS_PORT, () => log('Sidebar viewer ready (Home Assistant › BabyCam)'));

  const localServer = http.createServer(handleLocalRequest);
  localServer.on('error', (e) => log(`Local stream server error on port ${LOCAL_PORT}: ${e.message}`));
  localServer.listen(LOCAL_PORT, '127.0.0.1', () => {
    log('Home Assistant Generic Camera (no password needed):');
    log(`  Still image:   http://127.0.0.1:${LOCAL_PORT}/snapshot.jpg`);
    log(`  Stream source: http://127.0.0.1:${LOCAL_PORT}/stream.ts`);
  });

  if (DEV) {
    // localhost counts as a secure context, so the camera page works over plain http here.
    const devServer = http.createServer((req, res) => handleRequest(req, res, false));
    listen(devServer, false, options.port, announce);
    return;
  }
  await startHttps();
}

main().catch((e) => {
  log(`Fatal: ${e.stack || e}`);
  process.exit(1);
});
