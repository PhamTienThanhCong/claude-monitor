#!/usr/bin/env bash
# Stop -> Claude finished its turn and is now idle waiting for input -> free
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/_post.sh" free
