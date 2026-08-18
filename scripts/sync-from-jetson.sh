#!/usr/bin/env bash
# Pull Friday's source off the Jetson into this repository.
#
# Copies ONLY committable files. secrets.env, model weights, the venv, logs,
# backups, tmp, and the whisper.cpp / llama.cpp build trees are all excluded.
#
# Run from the repository root, on the machine that holds the repo.
#
#   ./scripts/sync-from-jetson.sh [user@host] [remote_root]

set -euo pipefail

HOST="${1:-sid@192.168.1.127}"
ROOT="${2:-/friday}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "source : $HOST:$ROOT"
echo "target : $REPO"
echo

if ! ssh -o ConnectTimeout=8 "$HOST" "test -d $ROOT"; then
  echo "ERROR: cannot reach $HOST or $ROOT does not exist" >&2
  exit 1
fi

rsync -av --prune-empty-dirs \
  --exclude='config/secrets.env' \
  --include='*/' \
  --include='src/friday/*.py' \
  --include='bin/*' \
  --include='models/wakewords/README.txt' \
  --exclude='*' \
  "$HOST:$ROOT/" "$REPO/"

# The systemd unit lives outside $ROOT.
mkdir -p "$REPO/deploy"
scp "$HOST:~/.config/systemd/user/friday.service" "$REPO/deploy/" 2>/dev/null \
  || echo "note: no systemd unit on the device yet"

echo
echo "--- pulled ---"
find "$REPO/src" "$REPO/bin" -type f 2>/dev/null | sed "s|$REPO/|  |" | sort

echo
echo "--- secret scan ---"
if grep -rInE '(sk-ant-|sk-[A-Za-z0-9]{20,}|ghp_|github_pat_|BEGIN [A-Z ]*PRIVATE KEY)' \
     "$REPO/src" "$REPO/bin" 2>/dev/null; then
  echo "REFUSING TO CONTINUE: credential material found above" >&2
  exit 2
fi
echo "  clean"

echo
echo "Review with 'git status', then commit."
