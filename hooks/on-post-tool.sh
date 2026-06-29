#!/usr/bin/env bash
# PostToolUse -> Claude just finished a tool, still active -> working
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/_post.sh" working
