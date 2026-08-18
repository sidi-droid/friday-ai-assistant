#!/usr/bin/env bash
# Push this repository's source back onto the Jetson.
#
# Deliberately conservative:
#   - dry-run by default; pass --apply to actually write
#   - only src/friday/*.py and bin/* are ever touched
#   - a timestamped backup is taken on the device first
#   - config/, models/, logs/ and secrets are never overwritten
#
#   ./scripts/deploy-to-jetson.sh [--apply] [user@host] [remote_root]

set -euo pipefail

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; shift; fi
HOST="${1:-sid@192.168.1.127}"
ROOT="${2:-/friday}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "target : $HOST:$ROOT"
echo "mode   : $([ $APPLY -eq 1 ] && echo APPLY || echo 'DRY RUN (pass --apply to write)')"
echo

ssh -o ConnectTimeout=8 "$HOST" "test -d $ROOT" \
  || { echo "ERROR: cannot reach $HOST:$ROOT" >&2; exit 1; }

if [ $APPLY -eq 1 ]; then
  STAMP=$(date +%Y%m%d-%H%M%S)
  echo "backing up current source on the device -> $ROOT/backups/deploy-$STAMP/"
  ssh "$HOST" "mkdir -p $ROOT/backups/deploy-$STAMP && \
               cp -a $ROOT/src/friday/*.py $ROOT/bin/* $ROOT/backups/deploy-$STAMP/ 2>/dev/null || true"
fi

RSYNC_FLAGS=(-av --checksum)
[ $APPLY -eq 1 ] || RSYNC_FLAGS+=(--dry-run)

rsync "${RSYNC_FLAGS[@]}" "$REPO/src/friday/"*.py "$HOST:$ROOT/src/friday/"
rsync "${RSYNC_FLAGS[@]}" "$REPO/bin/"            "$HOST:$ROOT/bin/"

if [ $APPLY -eq 1 ]; then
  echo
  echo "--- verifying on device ---"
  ssh "$HOST" "cd $ROOT && python3 -m py_compile src/friday/*.py && echo '  all modules compile'"
  ssh "$HOST" "cd /friday/src/friday && sha256sum tools.py command_policy.py operator.py executor.py"
  echo
  echo "Run the regression suite before trusting this:  ssh $HOST /friday/bin/friday-test"
fi
