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
fields = ['session_id', 'cwd', 'transcript_path', 'tool_name', 'hook_event_name']
# Use a non-whitespace separator (Unit Separator) so empty fields are preserved
# (read collapses adjacent whitespace separators like tabs, shifting columns).
print('\x1f'.join(str(d.get(f, '') or '') for f in fields))
" 2>/dev/null)"

IFS=$'\x1f' read -r SESSION_ID CWD TRANSCRIPT_PATH TOOL_NAME HOOK_EVENT <<< "$PARSED"

# Fallbacks
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
[ -z "$CWD" ] && CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

# Some tools block waiting for the user to choose/approve (AskUserQuestion shows
# options; ExitPlanMode asks to approve a plan). When such a tool is ABOUT to run
# (PreToolUse), that means Claude needs ME -> show "waiting" (red), not "working".
# On PostToolUse (the user already answered) it stays "working" and resumes.
WAITING_TOOLS=" AskUserQuestion ExitPlanMode "
if [ "$STATUS" = "working" ] && [ "$HOOK_EVENT" = "PreToolUse" ] \
   && [ -n "$TOOL_NAME" ] && [[ "$WAITING_TOOLS" == *" $TOOL_NAME "* ]]; then
  STATUS="waiting"
fi

# SessionEnd: remove this session from the dashboard, then exit.
if [ "$STATUS" = "delete" ]; then
  curl -s -m 2 -X DELETE "$ENDPOINT/$SESSION_ID" >/dev/null 2>&1 || true
  exit 0
fi

PROJECT="$(basename "$CWD")"

# From the transcript JSONL we pull two things in a single pass:
#   1. Conversation name: the latest "ai-title" (aiTitle); fall back to the
#      latest prompt, then the first user message.
#   2. Token usage: the context size of the LAST assistant turn — that is
#      input + cache_creation + cache_read tokens, i.e. how full the context
#      window currently is. Empty if the transcript isn't available yet.
# Output is three values separated by the Unit Separator: name, tokens, model.
CONVERSATION=""
TOKENS=""
MODEL=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  PARSED_TX="$(python3 -c "
import json, os
TAIL = 131072  # read only the last 128KB — newest ai-title & usage live near the end
title = last_prompt = first_user = ''
tokens = ''
model = ''
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
        elif t == 'assistant':
            m = d.get('message', {})
            u = m.get('usage') if isinstance(m, dict) else None
            if isinstance(u, dict):
                ctx = (u.get('input_tokens', 0) or 0) \
                    + (u.get('cache_creation_input_tokens', 0) or 0) \
                    + (u.get('cache_read_input_tokens', 0) or 0)
                if ctx:
                    tokens = ctx  # keep the LAST assistant turn's context size
            if m.get('model'):
                model = m['model']
    name = title or last_prompt or first_user
    name = ' '.join(name.split())  # collapse whitespace/newlines
    print('\x1f'.join([name[:60], str(tokens), model]))
except Exception:
    print('\x1f'.join(['', '', '']))
" 2>/dev/null)"
  IFS=$'\x1f' read -r CONVERSATION TOKENS MODEL <<< "$PARSED_TX"
fi

# Build JSON body safely with python3.
BODY="$(python3 -c "
import json
tokens = '''$TOKENS'''
print(json.dumps({
    'session_id': '''$SESSION_ID''',
    'project': '''$PROJECT''',
    'conversation': '''$CONVERSATION''',
    'status': '''$STATUS''',
    'tokens': int(tokens) if tokens.isdigit() else None,
    'model': '''$MODEL''',
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
