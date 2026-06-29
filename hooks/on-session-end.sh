#!/usr/bin/env bash
# SessionEnd -> window closed / exited / VS Code quit -> remove from dashboard
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/_post.sh" delete
