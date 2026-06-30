# Claude Monitor

A local-network **traffic-light dashboard** for your Claude Code sessions.
A small Node server receives status updates from Claude Code hooks and pushes
them over WebSocket to a dark, landscape-optimized dashboard you can keep open
on your phone.

- 🟢 **free** — session idle or done
- 🟡 **working** — Claude is actively using tools
- 🔴 **waiting** — Claude stopped and is waiting for your confirmation

## Setup

1. **Run the setup script** (generates the hook config for *your* clone path)

   ```bash
   cd <wherever-you-cloned-it>
   ./setup.sh
   ```

   It makes the hook scripts executable, creates `.env` (default `PORT=2202`) if
   missing, writes `.claude/settings.json` with absolute paths for your clone, and
   asks whether to also install the hooks globally (`~/.claude/settings.json`) so
   they fire for **every** Claude Code project — not just this folder. A backup of
   your existing global settings is made first, and re-running is safe
   (idempotent — it never duplicates or clobbers your other hooks).

   Flags: `./setup.sh --global` (install globally, no prompt) ·
   `./setup.sh --no-global` (project only).

2. **Install dependencies & start the server**

   ```bash
   npm install
   node server.js
   ```

   On startup it prints the URL to open on your phone, e.g.:

   ```
   Phone:    http://192.168.1.42:2202
   ```

3. **Open the dashboard on your phone**

   Open the printed **Phone URL** in Chrome/Safari (same Wi-Fi as your Mac),
   rotate to landscape, and tap the **⛶ Fullscreen** button (on iPhone, use
   *Add to Home Screen* for true fullscreen). The page keeps the screen awake via
   the Wake Lock API and auto-reconnects if the connection drops. Use the **⚙**
   button to resize the cards / toggle full-width (saved in `localStorage`).

### Why hooks need `setup.sh`

Claude Code hooks require **absolute paths**, which are machine-specific. The
generated `.claude/settings.json` is therefore git-ignored — each person who
clones the repo runs `./setup.sh` to produce their own. The Node server,
dashboard and hook scripts themselves do **not** depend on the `.claude/` folder.

## How it works

| Claude Code event                  | Hook script           | Result          |
|------------------------------------|-----------------------|-----------------|
| `SessionStart`                     | `on-session-start.sh` | `free` 🟢       |
| `UserPromptSubmit`                 | `on-user-prompt.sh`   | `working` 🟡    |
| `PreToolUse`                       | `on-pre-tool.sh`      | `working` 🟡    |
| `PostToolUse`                      | `on-post-tool.sh`     | `working` 🟡    |
| `Notification` (`permission_prompt`, `elicitation_dialog`) | `on-notification.sh` | `waiting` 🔴 |
| `PreToolUse` of `AskUserQuestion` / `ExitPlanMode` | `on-pre-tool.sh` | `waiting` 🔴 |
| `Stop`                             | `on-stop.sh`          | `free` 🟢       |
| `SessionEnd`                       | `on-session-end.sh`   | removed         |

- 🟢 **free** — Claude finished its turn / is idle, or a session just started
- 🟡 **working** — you submitted a prompt or Claude is using tools
- 🔴 **waiting** — Claude needs YOU: a permission prompt, or a blocking
  question/plan tool (`AskUserQuestion`, `ExitPlanMode`) that presents options to
  choose. `on-pre-tool.sh` inspects `tool_name`: when one of these tools is about
  to run it reports `waiting` instead of `working`; once you answer, `PostToolUse`
  flips it back to `working`.

Each hook reads the JSON context Claude Code sends on stdin (`session_id`, `cwd`,
`transcript_path`) and does a fire-and-forget request to the server. The
conversation name shown on each card is the AI-generated title (`ai-title`)
pulled from the tail of the session transcript — falling back to the latest
prompt, then the first user message, if no title exists yet. The server keeps an
in-memory `Map` of sessions and broadcasts the full list to every connected
browser on each change.

**Sessions are NOT removed on a timer.** A session lives until its `SessionEnd`
hook fires (you close the window, `/exit`, or quit VS Code), which removes it
from the dashboard. You can also tap a card to dismiss it manually.

**Known limitation — user interrupt.** Claude Code fires no hook when you
interrupt it mid-response (Esc / stop button); the `Stop` hook explicitly does
*not* run on an interrupt, and there is no abort/cancel event. So a card that was
`working` (yellow) stays yellow after an interrupt until the next signal — when
you submit a new prompt (`UserPromptSubmit` → working) or Claude finishes a turn
(`Stop` → free). This is intentional: the alternative (a timeout that flips
yellow→green) would misfire on legitimately long-running tools.

## Configuration (`.env`)

The port lives in a plain `.env` file at the project root so you can change it in
one place:

```
PORT=2202
CONTEXT_LIMIT=1000000
```

- `server.js` reads it on startup (a tiny built-in parser — no `dotenv`
  dependency). An existing `PORT` environment variable overrides the file.
- The hook scripts read the same `.env` to know where to POST, so changing the
  port keeps everything in sync.
- The dashboard connects to whatever host/port served the page, so it needs no
  change.
- `CONTEXT_LIMIT` is the context-window size used to show **how many tokens are
  left** on each card. Default `200000` (standard Claude); set `1000000` for
  `[1m]` models such as Opus 4.8 1M.

### Token usage

Each card shows a small bar with how full the session's context window is —
e.g. `192K / 1.0M · 19%` and `808K left`. The number is the **last assistant
turn's context size** (`input + cache_creation + cache_read` tokens) read
straight from the session transcript by the hooks, so it updates as Claude
works. The bar turns yellow past 60% and red past 85%. Toggle it off via the
**⚙** settings panel ("Show token usage").

### Plan usage (the `/usage` numbers)

A **PLAN USAGE** strip at the top of the dashboard mirrors Claude Code's
`/usage` command — your **5-hour session limit** and **weekly limits** (all
models / Opus / Sonnet), each with a percent, a colored bar, and a reset time.
A **↻** button forces an immediate refresh; otherwise it auto-polls every
`USAGE_POLL_SEC` seconds. Toggle it off via **⚙** ("Show plan usage").

**How it works (and caveats):** the server reads your Claude Code OAuth token
from the **macOS Keychain** (`Claude Code-credentials`) and calls the same
endpoint `/usage` uses (`api.anthropic.com/api/oauth/usage`).

- **macOS only.** Off macOS the strip stays hidden.
- The first time `node` reads the Keychain item, macOS shows a prompt — click
  **Always Allow** so the server can refresh it unattended.
- The token is kept fresh by Claude Code itself (the server re-reads the
  Keychain on each poll). If it ever shows "Token expired", open Claude Code.
- This endpoint is **undocumented / unofficial** — it may change without notice.
  Every failure degrades to a small message instead of crashing. Set
  `TRACK_USAGE=false` in `.env` to turn the whole feature off.

After changing the port, restart the server (`node server.js`).

## Endpoints

- `POST /status` — `{ session_id, project, conversation, status, tokens, model }`
- `GET /usage` — force-refresh plan usage now and return it (the dashboard's ↻)
- `GET /` — serves the dashboard
- `WebSocket` (same port **2202**) — broadcasts the sessions array

## Test it manually

With the server running:

```bash
curl -X POST http://localhost:2202/status \
  -H "Content-Type: application/json" \
  -d '{"session_id":"test-123","project":"demo","conversation":"hello","status":"working"}'
```

The dashboard should show a yellow card within ~1 second. Send `status:"waiting"`
to turn it red, `status:"free"` for green. Stop sending and it disappears after 25s.

## Requirements

- Node.js (any recent LTS)
- `python3` and `curl` (preinstalled on macOS) — used by the hook scripts
