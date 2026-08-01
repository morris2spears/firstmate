#!/usr/bin/env bash
# Poll durable carbon peer-relay requests for the authenticated watcher check.
# Output is one compact ids-only payload or silence; request bodies never enter
# watcher output or state/.wake-queue.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-peer-relay-lib.sh
. "$SCRIPT_DIR/fm-peer-relay-lib.sh"

fmpeer_enabled "$FM_HOME" || exit 0
STORE=$(fmpeer_store_dir "$STATE")
[ -d "$STORE" ] && [ ! -L "$STORE" ] || exit 0
OFFERED=$(fmpeer_offered_dir "$STATE")
NOW=${FMPEER_NOW_OVERRIDE:-$(date +%s)}
fmpeer_epoch_valid "$NOW" || exit 0
REOFFER=${FMPEER_REOFFER_SECS:-1800}
case "$REOFFER" in
  ''|*[!0-9]*) REOFFER=1800 ;;
esac

WAKE_IDS=
for request_dir in "$STORE"/*; do
  [ -e "$request_dir" ] || continue
  id=${request_dir##*/}
  fmpeer_request_id_valid "$id" || continue
  fmpeer_request_dir_valid "$STATE" "$id" || continue
  [ "$(fmpeer_status_get "$request_dir")" = pending ] || {
    if fmx_private_artifact_dir_device "$OFFERED" >/dev/null 2>&1; then
      rm -f -- "$OFFERED/$id" 2>/dev/null || true
    fi
    continue
  }

  if fmx_private_artifact_file_valid "$OFFERED" "$id" 600; then
    mtime=$(fmpeer_stat_mtime "$OFFERED/$id") || continue
    age=$((NOW - mtime))
    [ "$age" -ge "$REOFFER" ] || continue
    printf '%s\n' "$NOW" \
      | fmx_private_artifact_publish_stdin "$OFFERED" "$id" 600 2>/dev/null \
      || continue
    WAKE_IDS="$WAKE_IDS $id"
    continue
  fi
  if [ -e "$OFFERED/$id" ] || [ -L "$OFFERED/$id" ]; then
    continue
  fi
  printf '%s\n' "$NOW" \
    | fmx_private_artifact_publish_stdin_once "$OFFERED" "$id" 600 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || continue
  WAKE_IDS="$WAKE_IDS $id"
done

[ -n "$WAKE_IDS" ] || exit 0
printf 'peer-relay-request%s\n' "$WAKE_IDS"
