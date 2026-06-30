// Plan-usage tracker — surfaces the same numbers as Claude Code's `/usage`
// (5-hour session limit, weekly limits) on the dashboard.
//
// HOW: Claude Code stores its OAuth token in the macOS Keychain under the
// service name "Claude Code-credentials". We read that token and call the same
// (undocumented) endpoint `/usage` uses. Because Claude Code refreshes the
// token in the Keychain while it runs, re-reading it on every poll keeps us
// authenticated without implementing the refresh flow ourselves.
//
// CAVEATS:
//   - macOS only (Keychain). On other platforms this stays disabled.
//   - The endpoint is undocumented and may change; every failure degrades to a
//     soft { error } that the dashboard shows instead of crashing.
//   - First time `node` reads the Keychain item, macOS prompts the user to
//     allow access ("Always Allow" makes it persistent).

const { execFile } = require('child_process');
const os = require('os');

const USAGE_ENDPOINT = 'https://api.anthropic.com/api/oauth/usage';
const KEYCHAIN_SERVICE = 'Claude Code-credentials';

// Read the Claude Code OAuth blob from the macOS Keychain. Resolves to the
// oauth object ({ accessToken, ... }) or null if unavailable.
function readToken() {
  return new Promise((resolve) => {
    if (os.platform() !== 'darwin') return resolve(null);
    execFile(
      'security',
      ['find-generic-password', '-s', KEYCHAIN_SERVICE, '-w'],
      { timeout: 5000 },
      (err, stdout) => {
        if (err) return resolve(null);
        try {
          const d = JSON.parse(stdout);
          const oa = d.claudeAiOauth || d.claude_ai_oauth || {};
          resolve(oa.accessToken ? oa : null);
        } catch (e) {
          resolve(null);
        }
      }
    );
  });
}

// Latest result: { data, fetchedAt } on success, { error, fetchedAt } on failure.
let latest = null;

async function fetchUsage() {
  if (os.platform() !== 'darwin') {
    latest = { error: 'unsupported-platform', fetchedAt: Date.now() };
    return latest;
  }
  const oa = await readToken();
  if (!oa) {
    latest = { error: 'no-credentials', fetchedAt: Date.now() };
    return latest;
  }
  try {
    const res = await fetch(USAGE_ENDPOINT, {
      headers: {
        Authorization: `Bearer ${oa.accessToken}`,
        'anthropic-beta': 'oauth-2025-04-20',
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
    });
    if (res.status === 401) {
      latest = { error: 'expired', fetchedAt: Date.now() };
      return latest;
    }
    if (!res.ok) {
      latest = { error: `http-${res.status}`, fetchedAt: Date.now() };
      return latest;
    }
    const data = await res.json();
    latest = { data, fetchedAt: Date.now() };
    return latest;
  } catch (e) {
    latest = { error: 'fetch-failed', fetchedAt: Date.now() };
    return latest;
  }
}

function getLatest() {
  return latest;
}

module.exports = { fetchUsage, getLatest };
