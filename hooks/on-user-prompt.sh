#!/usr/bin/env bash
# UserPromptSubmit -> you sent a prompt, Claude is now working -> working (yellow)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/_post.sh" working
