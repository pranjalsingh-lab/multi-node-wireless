'use strict';

const express = require('express');
const multer = require('multer');
const net = require('net');
const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');

// ----------------------------------------------------------------------------
// Paths & configuration
// ----------------------------------------------------------------------------
const APP_DIR = __dirname;
const ROOT = path.resolve(APP_DIR, '..');
const RENODE_DIR = path.join(ROOT, 'vendor', 'renode');
const RENODE_BIN = path.join(RENODE_DIR, 'renode');
const DEFAULT_FW_DIR = path.join(ROOT, 'firmware', 'defaults');
const UPLOAD_FW_DIR = path.join(ROOT, 'firmware', 'uploads');
const WORK_DIR = path.join(ROOT, 'work');
const RESC_PATH = path.join(WORK_DIR, 'run.resc');
const RENODE_LOG = path.join(WORK_DIR, 'renode.log');

for (const d of [UPLOAD_FW_DIR, WORK_DIR]) fs.mkdirSync(d, { recursive: true });

const MONITOR_PORT = 33000;

// The three virtual devices. Renode is an implementation detail and never
// named in anything the client sees.
const NODES = [
  {
    id: 'gateway',
    label: 'Gateway',
    role: 'Bluetooth LE · Central',
    blurb: 'Scans for nearby devices, connects, and collects live readings.',
    uartPort: 33101,
    ble: true,
    sensor: false,
    defaultFw: 'gateway.elf',
  },
  {
    id: 'heartrate',
    label: 'Heart-Rate Band',
    role: 'Bluetooth LE · Peripheral',
    blurb: 'Advertises a heart-rate service and streams beats per minute.',
    uartPort: 33102,
    ble: true,
    sensor: false,
    defaultFw: 'heartrate.elf',
  },
  {
    id: 'motion',
    label: 'Motion Sensor Node',
    role: 'ADXL372 accelerometer · SPI',
    blurb: 'Reads a 3-axis accelerometer over SPI. Drag the sliders to move it.',
    uartPort: 33103,
    ble: false,
    sensor: true,
    defaultFw: 'motion.elf',
  },
];

// ----------------------------------------------------------------------------
// Runtime state
// ----------------------------------------------------------------------------
const state = {
  running: false,
  child: null,
  uartSockets: {}, // id -> net.Socket
  uartPartial: {}, // id -> leftover string
  monitorSocket: null,
  rings: Object.fromEntries(NODES.map((n) => [n.id, []])), // id -> recent lines
  uploadedNames: {}, // id -> original filename
};
const RING_CAP = 500;
const sseClients = new Set();

// Restore uploaded-firmware awareness across restarts.
for (const n of NODES) {
  const f = path.join(UPLOAD_FW_DIR, `${n.id}.elf`);
  if (fs.existsSync(f)) state.uploadedNames[n.id] = '(custom firmware)';
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------
const ANSI = /\x1b\[[0-9;]*[A-Za-z]/g;

function firmwareFor(node) {
  const uploaded = path.join(UPLOAD_FW_DIR, `${node.id}.elf`);
  if (fs.existsSync(uploaded)) {
    return { path: uploaded, source: 'custom', name: state.uploadedNames[node.id] || '(custom firmware)' };
  }
  return { path: path.join(DEFAULT_FW_DIR, node.defaultFw), source: 'default', name: node.defaultFw };
}

function nodesPublic() {
  return NODES.map((n) => {
    const fw = firmwareFor(n);
    return {
      id: n.id, label: n.label, role: n.role, blurb: n.blurb,
      ble: n.ble, sensor: n.sensor,
      firmware: { source: fw.source, name: fw.name, exists: fs.existsSync(fw.path) },
    };
  });
}

function sse(type, payload) {
  const data = JSON.stringify(Object.assign({ type }, payload));
  for (const res of sseClients) {
    try { res.write(`data: ${data}\n\n`); } catch (_) {}
  }
}

function pushLine(id, line) {
  const ring = state.rings[id];
  ring.push(line);
  if (ring.length > RING_CAP) ring.splice(0, ring.length - RING_CAP);
  sse('line', { node: id, line });
}

function buildResc() {
  const L = [];
  L.push(':name: multi-node wireless lab');
  L.push('');
  L.push('emulation CreateBLEMedium "wireless"');
  L.push('');
  for (const n of NODES) {
    L.push(`mach create "${n.id}"`);
    if (n.sensor) {
      // nRF52840 + ADXL372 accelerometer on SPI (chip-select on gpio0 pin 22)
      L.push('machine LoadPlatformDescriptionFromString """');
      L.push('using "platforms/cpus/nrf52840.repl"');
      L.push('adxl372: Sensors.ADXL372 @ spi2');
      L.push('gpio0:');
      L.push('    22 -> adxl372@0');
      L.push('"""');
    } else {
      L.push('machine LoadPlatformDescription @platforms/cpus/nrf52840.repl');
    }
    if (n.ble) L.push('connector Connect sysbus.radio wireless');
    L.push(`emulation CreateServerSocketTerminal ${n.uartPort} "term_${n.id}" false`);
    L.push(`connector Connect sysbus.uart0 term_${n.id}`);
    L.push('');
  }
  // BLE link layer is timing-sensitive; tight quantum keeps the nodes in sync.
  L.push('emulation SetGlobalQuantum "0.00001"');
  L.push('');
  L.push('macro reset');
  L.push('"""');
  for (const n of NODES) {
    const fw = firmwareFor(n);
    L.push(`    mach set "${n.id}"`);
    L.push(`    sysbus LoadELF @${fw.path}`);
  }
  L.push('"""');
  L.push('runMacro $reset');
  L.push('start');
  L.push('');
  return L.join('\n');
}

function connectUart(node) {
  const tryConnect = (attempt) => {
    const sock = net.connect(node.uartPort, '127.0.0.1');
    sock.setNoDelay(true);
    state.uartPartial[node.id] = '';
    sock.on('connect', () => { state.uartSockets[node.id] = sock; });
    sock.on('data', (buf) => {
      let s = state.uartPartial[node.id] + buf.toString('utf8');
      s = s.replace(ANSI, '').replace(/\r/g, '\n');
      const parts = s.split('\n');
      state.uartPartial[node.id] = parts.pop();
      for (const p of parts) if (p.length) pushLine(node.id, p);
    });
    sock.on('error', () => {});
    sock.on('close', () => {
      delete state.uartSockets[node.id];
      if (state.running && attempt < 60) setTimeout(() => tryConnect(attempt + 1), 500);
    });
  };
  tryConnect(0);
}

function connectMonitor() {
  const tryConnect = (attempt) => {
    const sock = net.connect(MONITOR_PORT, '127.0.0.1');
    sock.setNoDelay(true);
    sock.on('connect', () => { state.monitorSocket = sock; });
    sock.on('data', () => {}); // drain telnet chatter
    sock.on('error', () => {});
    sock.on('close', () => {
      state.monitorSocket = null;
      if (state.running && attempt < 60) setTimeout(() => tryConnect(attempt + 1), 500);
    });
  };
  tryConnect(0);
}

function monitorCmd(cmd) {
  if (state.monitorSocket && !state.monitorSocket.destroyed) {
    state.monitorSocket.write(cmd + '\r\n');
    return true;
  }
  return false;
}

function killStray() {
  return new Promise((resolve) => {
    // Targeted: only our bundled renode, never the node server.
    execFile('pkill', ['-9', '-f', 'multi-node-wireless/vendor/renode'], () => resolve());
  });
}

async function startEmulation() {
  if (state.running) await stopEmulation();
  await killStray();
  await new Promise((r) => setTimeout(r, 400));

  for (const n of NODES) state.rings[n.id] = [];

  fs.writeFileSync(RESC_PATH, buildResc());
  const logFd = fs.openSync(RENODE_LOG, 'w');

  const child = spawn(RENODE_BIN, ['--disable-xwt', '-P', String(MONITOR_PORT), RESC_PATH], {
    cwd: RENODE_DIR,
    detached: true,
    stdio: ['ignore', logFd, logFd],
  });
  state.child = child;
  state.running = true;
  sse('status', { running: true, phase: 'starting' });

  child.on('exit', (code) => {
    if (state.child === child) {
      state.child = null;
      state.running = false;
      for (const id of Object.keys(state.uartSockets)) {
        try { state.uartSockets[id].destroy(); } catch (_) {}
      }
      state.uartSockets = {};
      if (state.monitorSocket) { try { state.monitorSocket.destroy(); } catch (_) {} state.monitorSocket = null; }
      sse('status', { running: false, phase: 'stopped' });
    }
  });

  // Give Renode a moment to open its sockets, then connect.
  setTimeout(() => {
    if (!state.running) return;
    connectMonitor();
    for (const n of NODES) connectUart(n);
    sse('status', { running: true, phase: 'running' });
  }, 1500);
}

function stopEmulation() {
  return new Promise(async (resolve) => {
    const child = state.child;
    state.running = false;
    for (const id of Object.keys(state.uartSockets)) {
      try { state.uartSockets[id].destroy(); } catch (_) {}
    }
    state.uartSockets = {};
    if (state.monitorSocket) { try { state.monitorSocket.destroy(); } catch (_) {} state.monitorSocket = null; }
    if (child && child.pid) {
      try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {}
      try { child.kill('SIGKILL'); } catch (_) {}
    }
    state.child = null;
    await killStray();
    sse('status', { running: false, phase: 'stopped' });
    setTimeout(resolve, 500);
  });
}

// ----------------------------------------------------------------------------
// HTTP API
// ----------------------------------------------------------------------------
const app = express();
app.use(express.json());
app.use(express.static(path.join(APP_DIR, 'public')));

const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => cb(null, UPLOAD_FW_DIR),
    filename: (req, file, cb) => cb(null, `${req.params.node}.elf`),
  }),
  limits: { fileSize: 64 * 1024 * 1024 },
});

app.get('/api/state', (req, res) => {
  res.json({ running: state.running, nodes: nodesPublic() });
});

app.get('/api/events', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });
  res.write('retry: 2000\n\n');
  sseClients.add(res);
  // Initial snapshot: status + recent history so a fresh tab shows context.
  res.write(`data: ${JSON.stringify({ type: 'hello', running: state.running, nodes: nodesPublic(), history: state.rings })}\n\n`);
  req.on('close', () => sseClients.delete(res));
});

app.post('/api/start', async (req, res) => {
  try { await startEmulation(); res.json({ ok: true }); }
  catch (e) { res.status(500).json({ ok: false, error: 'failed to start' }); }
});

app.post('/api/stop', async (req, res) => {
  await stopEmulation();
  res.json({ ok: true });
});

app.post('/api/sensor', (req, res) => {
  const { axis, value } = req.body || {};
  if (!['X', 'Y', 'Z'].includes(axis)) return res.status(400).json({ ok: false });
  const v = Math.max(-10, Math.min(10, Number(value) || 0));
  monitorCmd('mach set "motion"');
  const ok = monitorCmd(`sysbus.spi2.adxl372 Acceleration${axis} ${v}`);
  sse('sensor', { axis, value: v });
  res.json({ ok });
});

app.post('/api/upload/:node', upload.single('firmware'), (req, res) => {
  const node = NODES.find((n) => n.id === req.params.node);
  if (!node || !req.file) return res.status(400).json({ ok: false });
  state.uploadedNames[node.id] = req.file.originalname;
  sse('firmware', { node: node.id, firmware: { source: 'custom', name: req.file.originalname, exists: true } });
  res.json({ ok: true, name: req.file.originalname });
});

app.post('/api/reset-firmware/:node', (req, res) => {
  const node = NODES.find((n) => n.id === req.params.node);
  if (!node) return res.status(404).json({ ok: false });
  const f = path.join(UPLOAD_FW_DIR, `${node.id}.elf`);
  if (fs.existsSync(f)) fs.unlinkSync(f);
  delete state.uploadedNames[node.id];
  const fw = firmwareFor(node);
  sse('firmware', { node: node.id, firmware: { source: 'default', name: fw.name, exists: fs.existsSync(fw.path) } });
  res.json({ ok: true });
});

process.on('SIGINT', async () => { await stopEmulation(); process.exit(0); });
process.on('SIGTERM', async () => { await stopEmulation(); process.exit(0); });

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => {
  console.log(`Wireless Device Lab running:  http://localhost:${PORT}`);
});
