#!/usr/bin/env bash
# PreToolUse -> Claude is about to use a tool -> working
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/_post.sh" working
