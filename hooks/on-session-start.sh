#!/usr/bin/env bash
# SessionStart -> a new session began, idle -> free
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/_post.sh" free
