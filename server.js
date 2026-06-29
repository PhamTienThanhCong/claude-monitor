const express = require('express');
const http = require('http');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { WebSocketServer } = require('ws');

// Minimal .env loader (no dependency). Values already in process.env win.
function loadEnv() {
  try {
    const file = path.join(__dirname, '.env');
    for (const raw of fs.readFileSync(file, 'utf8').split('\n')) {
      const line = raw.trim();
      if (!line || line.startsWith('#')) continue;
      const eq = line.indexOf('=');
      if (eq === -1) continue;
      const key = line.slice(0, eq).trim();
      const val = line.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
      if (key && process.env[key] === undefined) process.env[key] = val;
    }
  } catch (e) { /* no .env file — use defaults */ }
}
loadEnv();

const PORT = parseInt(process.env.PORT, 10) || 2202;

const app = express();
app.use(express.json());
// Serve static assets (index.html, icons, manifest) from public/.
app.use(express.static(path.join(__dirname, 'public')));

const server = http.createServer(app);
const wss = new WebSocketServer({ server });

// session_id -> { session_id, project, conversation, status, lastSeen }
const sessions = new Map();

function sessionsArray() {
  return Array.from(sessions.values());
}

function broadcast() {
  const payload = JSON.stringify({ type: 'sessions', sessions: sessionsArray() });
  for (const client of wss.clients) {
    if (client.readyState === client.OPEN) {
      client.send(payload);
    }
  }
}

// --- HTTP endpoints ---

app.post('/status', (req, res) => {
  const { session_id, project, conversation, status } = req.body || {};

  if (!session_id) {
    return res.status(400).json({ error: 'session_id required' });
  }

  const validStatus = ['free', 'working', 'waiting'].includes(status)
    ? status
    : 'free';

  const existing = sessions.get(session_id) || {};
  sessions.set(session_id, {
    session_id,
    project: project || existing.project || 'unknown',
    conversation: conversation || existing.conversation || '',
    status: validStatus,
    lastSeen: Date.now(),
  });

  broadcast();
  res.json({ ok: true });
});

// Manually dismiss a session (tap a card on the dashboard).
app.delete('/status/:id', (req, res) => {
  if (sessions.delete(req.params.id)) {
    broadcast();
  }
  res.json({ ok: true });
});

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// --- WebSocket: send current state on connect ---

wss.on('connection', (ws) => {
  ws.send(JSON.stringify({ type: 'sessions', sessions: sessionsArray() }));
});

// --- Heartbeat: prune stale sessions ---

// NOTE: Sessions are intentionally NOT pruned by time. A session lives until
// it is explicitly removed via SessionEnd (DELETE /status/:id) — i.e. when the
// user closes the window / exits the terminal / quits VS Code — or is dismissed
// by tapping its card on the dashboard.

// --- Local IP discovery ---

function getLocalIP() {
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        return iface.address;
      }
    }
  }
  return '127.0.0.1';
}

server.listen(PORT, '0.0.0.0', () => {
  const ip = getLocalIP();
  console.log('\n  Claude Monitor is running');
  console.log('  ─────────────────────────────');
  console.log(`  Local:    http://localhost:${PORT}`);
  console.log(`  Phone:    http://${ip}:${PORT}`);
  console.log('  ─────────────────────────────');
  console.log('  Open the Phone URL in your browser (same Wi-Fi).\n');
});
