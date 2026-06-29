#!/usr/bin/env bash
#
# Claude Monitor — one-time setup.
# Generates the Claude Code hook config with ABSOLUTE paths pointing at THIS
# clone, so it works no matter where you cloned the project.
#
# Usage:
#   ./setup.sh              # set up project hooks, then ask about global install
#   ./setup.sh --global     # also install into ~/.claude/settings.json (no prompt)
#   ./setup.sh --no-global  # project only, no prompt
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$ROOT/hooks"

echo "Claude Monitor setup"
echo "  Project: $ROOT"
echo

# 1. Make hook scripts executable
chmod +x "$HOOKS_DIR"/*.sh
echo "✓ hook scripts are executable"

# 2. Create a default .env if missing
if [ ! -f "$ROOT/.env" ]; then
  printf '# Claude Monitor configuration\n# Port the server listens on (and the port hooks POST to).\nPORT=2202\n' > "$ROOT/.env"
  echo "✓ created .env (default PORT=2202)"
else
  echo "✓ .env already exists (left untouched)"
fi

# Shared generator: writes/merges the hook config into a target settings.json.
# Args: <target-file> <mode: project|global>
gen_hooks() {
  python3 - "$ROOT" "$1" "$2" <<'PY'
import json, os, sys

root, target, mode = sys.argv[1], sys.argv[2], sys.argv[3]
hooks_dir = os.path.join(root, "hooks")

# (event, matcher-or-None, script)
defs = [
    ("SessionStart",     None,                "on-session-start.sh"),
    ("UserPromptSubmit", None,                "on-user-prompt.sh"),
    ("PreToolUse",       "*",                 "on-pre-tool.sh"),
    ("PostToolUse",      "*",                 "on-post-tool.sh"),
    ("Notification",     "permission_prompt", "on-notification.sh"),
    ("Stop",             None,                "on-stop.sh"),
    ("SessionEnd",       None,                "on-session-end.sh"),
]
our_scripts = {s for _, _, s in defs}

def group(matcher, script):
    g = {"hooks": [{"type": "command", "command": os.path.join(hooks_dir, script)}]}
    return ({"matcher": matcher, **g} if matcher is not None else g)

ours = {}
for ev, m, s in defs:
    ours.setdefault(ev, []).append(group(m, s))

def is_ours(g):
    # True if any command in this group is one of our hook scripts (any path) —
    # lets re-running setup replace a prior install even if the clone moved.
    for h in g.get("hooks", []):
        cmd = h.get("command", "")
        if "/hooks/" in cmd and os.path.basename(cmd) in our_scripts:
            return True
    return False

if mode == "project":
    data = {"hooks": ours}
else:
    data = {}
    if os.path.exists(target):
        try:
            with open(target) as f:
                data = json.load(f)
        except Exception:
            data = {}
    existing = data.get("hooks", {}) or {}
    # Drop any previous claude-monitor entries, keep the user's other hooks.
    for ev in list(existing.keys()):
        existing[ev] = [g for g in existing[ev] if not is_ours(g)]
    # Add ours.
    for ev, groups in ours.items():
        existing.setdefault(ev, []).extend(groups)
    # Remove now-empty event arrays.
    existing = {k: v for k, v in existing.items() if v}
    data["hooks"] = existing

os.makedirs(os.path.dirname(target), exist_ok=True)
with open(target, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

# 3. Project-scoped config (sessions started inside this folder)
gen_hooks "$ROOT/.claude/settings.json" "project"
echo "✓ wrote .claude/settings.json (project hooks)"

# 4. Optional global install (all projects)
DO_GLOBAL=""
for a in "$@"; do
  case "$a" in
    --global)    DO_GLOBAL="yes" ;;
    --no-global) DO_GLOBAL="no" ;;
  esac
done

if [ -z "$DO_GLOBAL" ]; then
  if [ -t 0 ]; then
    read -r -p "Also install hooks globally (~/.claude/settings.json, all projects)? [Y/n] " ans
    case "${ans:-Y}" in [Nn]*) DO_GLOBAL="no" ;; *) DO_GLOBAL="yes" ;; esac
  else
    DO_GLOBAL="no"  # non-interactive: skip global by default
  fi
fi

if [ "$DO_GLOBAL" = "yes" ]; then
  GLOBAL="$HOME/.claude/settings.json"
  [ -f "$GLOBAL" ] && cp "$GLOBAL" "$GLOBAL.bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
  gen_hooks "$GLOBAL" "global"
  echo "✓ merged hooks into $GLOBAL (a .bak backup was made if it existed)"
else
  echo "• skipped global install"
fi

echo
echo "Done. Next:"
echo "  1) npm install"
echo "  2) node server.js   (prints the phone URL)"
echo "  3) open that URL on your phone (same Wi-Fi)"
