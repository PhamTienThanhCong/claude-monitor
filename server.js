const express = require('express');
const http = require('http');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { WebSocketServer } = require('ws');
const { fetchUsage, getLatest } = require('./usage');

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
// How big the context window is, so the dashboard can show "X left".
// Default 200000 (standard Claude); set CONTEXT_LIMIT=1000000 for [1m] models.
const CONTEXT_LIMIT = parseInt(process.env.CONTEXT_LIMIT, 10) || 200000;
// Poll the plan-usage endpoint (mirrors `/usage`). Set TRACK_USAGE=false to
// disable. How often to refresh, in seconds.
const TRACK_USAGE = String(process.env.TRACK_USAGE || 'true').toLowerCase() !== 'false';
const USAGE_POLL_SEC = parseInt(process.env.USAGE_POLL_SEC, 10) || 60;

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
  const payload = JSON.stringify({
    type: 'sessions',
    sessions: sessionsArray(),
    contextLimit: CONTEXT_LIMIT,
    usage: TRACK_USAGE ? getLatest() : null,
  });
  for (const client of wss.clients) {
    if (client.readyState === client.OPEN) {
      client.send(payload);
    }
  }
}

// --- HTTP endpoints ---

app.post('/status', (req, res) => {
  const { session_id, project, conversation, status, tokens, model } = req.body || {};

  if (!session_id) {
    return res.status(400).json({ error: 'session_id required' });
  }

  const validStatus = ['free', 'working', 'waiting'].includes(status)
    ? status
    : 'free';

  const existing = sessions.get(session_id) || {};
  // Keep the last known token count if this update doesn't carry a fresh one
  // (e.g. SessionStart, before any assistant turn exists).
  const validTokens = Number.isFinite(tokens) && tokens > 0
    ? tokens
    : existing.tokens;

  sessions.set(session_id, {
    session_id,
    project: project || existing.project || 'unknown',
    conversation: conversation || existing.conversation || '',
    status: validStatus,
    tokens: validTokens,
    model: model || existing.model || '',
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

// Force-refresh the plan usage now (the dashboard's ↻ button), then push it.
app.get('/usage', async (req, res) => {
  if (!TRACK_USAGE) return res.json({ error: 'disabled' });
  const result = await fetchUsage();
  broadcast();
  res.json(result || { error: 'unavailable' });
});

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// --- WebSocket: send current state on connect ---

wss.on('connection', (ws) => {
  ws.send(JSON.stringify({
    type: 'sessions',
    sessions: sessionsArray(),
    contextLimit: CONTEXT_LIMIT,
  }));
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

  // Start polling plan usage (mirrors `/usage`) and push updates as they land.
  if (TRACK_USAGE) {
    const poll = async () => {
      await fetchUsage();
      broadcast();
    };
    poll();
    setInterval(poll, USAGE_POLL_SEC * 1000);
  }
});
