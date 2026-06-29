#!/usr/bin/env bash
# Notification -> Claude needs your attention (permission prompt / choose an
# option / confirm) -> waiting (red)
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/_post.sh" waiting
