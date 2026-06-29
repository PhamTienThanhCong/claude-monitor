#!/usr/bin/env bash
# Shared helper: read Claude Code hook JSON from stdin and update the monitor.
# Usage: _post.sh <free|working|waiting|delete>
#   - free|working|waiting -> POST a status update
#   - delete               -> DELETE the session (used by SessionEnd)
#
# Claude Code passes hook context as JSON on stdin, e.g.:
#   { "session_id": "...", "cwd": "/path/to/project", "transcript_path": "...", ... }

STATUS="${1:-free}"

# Resolve PORT: env var wins, else read it from ../.env, else default 2202.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -z "$PORT" ] && [ -f "$ENV_FILE" ]; then
  PORT="$(grep -E '^[[:space:]]*PORT[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d= -f2 | tr -d '[:space:]"'"'"'')"
fi
[ -z "$PORT" ] && PORT=2202
ENDPOINT="http://localhost:$PORT/status"

# Read all of stdin (the hook JSON). May be empty for some events.
INPUT="$(cat)"

# Parse the fields we need in a single python3 pass (robust JSON parsing).
# session_id is STABLE across a resume, so it is our conversation identity.
# Emits tab-separated: session_id, cwd, transcript_path
PARSED="$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print('\t'.join(str(d.get(f, '') or '') for f in ['session_id', 'cwd', 'transcript_path']))
" 2>/dev/null)"

IFS=$'\t' read -r SESSION_ID CWD TRANSCRIPT_PATH <<< "$PARSED"

# Fallbacks
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
[ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

# SessionEnd: remove this session from the dashboard, then exit.
if [ "$STATUS" = "delete" ]; then
  curl -s -m 2 -X DELETE "$ENDPOINT/$SESSION_ID" >/dev/null 2>&1 || true
  exit 0
fi

PROJECT="$(basename "$CWD")"

# Conversation name: pull the AI-generated title from the transcript JSONL.
# Prefer the latest "ai-title" (aiTitle); fall back to the latest prompt, then
# to the first user message. Empty if the transcript isn't available yet.
CONVERSATION=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  CONVERSATION="$(python3 -c "
import json, os
TAIL = 131072  # read only the last 128KB — newest ai-title lives near the end
title = last_prompt = first_user = ''
try:
    path = '''$TRANSCRIPT_PATH'''
    size = os.path.getsize(path)
    with open(path, 'r') as f:
        if size > TAIL:
            f.seek(size - TAIL)
            f.readline()  # discard the partial first line after seeking
        lines = f.readlines()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get('type')
        if t == 'ai-title' and d.get('aiTitle'):
            title = d['aiTitle']
        elif t == 'last-prompt' and d.get('lastPrompt'):
            last_prompt = d['lastPrompt']
        elif t == 'user' and not first_user:
            m = d.get('message', {})
            c = m.get('content') if isinstance(m, dict) else None
            if isinstance(c, str):
                first_user = c
            elif isinstance(c, list):
                for p in c:
                    if isinstance(p, dict) and p.get('type') == 'text':
                        first_user = p.get('text', '')
                        break
    name = title or last_prompt or first_user
    name = ' '.join(name.split())  # collapse whitespace/newlines
    print(name[:60])
except Exception:
    print('')
" 2>/dev/null)"
fi

# Build JSON body safely with python3.
BODY="$(python3 -c "
import json
print(json.dumps({
    'session_id': '''$SESSION_ID''',
    'project': '''$PROJECT''',
    'conversation': '''$CONVERSATION''',
    'status': '''$STATUS''',
}))
" 2>/dev/null)"

# If python3 unavailable, build a minimal body by hand.
if [ -z "$BODY" ]; then
  BODY="{\"session_id\":\"$SESSION_ID\",\"project\":\"$PROJECT\",\"conversation\":\"\",\"status\":\"$STATUS\"}"
fi

# Fire-and-forget; never block Claude Code. Short timeout.
curl -s -m 2 -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "$BODY" >/dev/null 2>&1 || true

exit 0
