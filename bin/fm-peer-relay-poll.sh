#!/usr/bin/env bash
# Poll durable carbon peer-relay requests for the authenticated watcher check.
# Output is one compact ids-only payload or silence; request bodies never enter
# watcher output or state/.wake-queue.
#
# A marker path that is not a valid private artifact, or an offer that cannot be
# recorded, would otherwise strand a captain request in pending forever with no
# diagnostic. Like the Telegram poll, that state is surfaced once as
# "peer-relay-error <msg>" and stays quiet until it clears and recurs.
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

ERROR_DIR="$STATE/peer-relay/poll"

emit_error_once() {
  local base=$1 msg=$2
  if fmx_private_artifact_file_valid "$ERROR_DIR" "$base" 600 \
    && [ "$(cat "$ERROR_DIR/$base" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$ERROR_DIR" "$base" 600 2>/dev/null || true
  printf 'peer-relay-error %s\n' "$msg"
}

clear_error() {
  local base=$1
  fmx_private_artifact_dir_device "$ERROR_DIR" >/dev/null 2>&1 || return 0
  rm -f -- "$ERROR_DIR/$base" 2>/dev/null || true
}

fmpeer_retention_prune "$STATE" "$NOW"

WAKE_IDS=
claim_failed=0
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
    if printf '%s\n' "$NOW" \
      | fmx_private_artifact_publish_stdin "$OFFERED" "$id" 600 2>/dev/null; then
      WAKE_IDS="$WAKE_IDS $id"
    else
      claim_failed=1
    fi
    continue
  fi
  if [ -e "$OFFERED/$id" ] || [ -L "$OFFERED/$id" ]; then
    # An offer marker that is not a valid private artifact is tampering, not a
    # normal state; never emit around it, and never leave it silent either.
    claim_failed=1
    continue
  fi
  printf '%s\n' "$NOW" \
    | fmx_private_artifact_publish_stdin_once "$OFFERED" "$id" 600 2>/dev/null
  rc=$?
  case "$rc" in
    0) WAKE_IDS="$WAKE_IDS $id" ;;
    1) : ;;
    *) claim_failed=1 ;;
  esac
done

if [ "$claim_failed" -eq 1 ]; then
  emit_error_once claim-error 'cannot record peer relay offer'
else
  clear_error claim-error
fi

[ -n "$WAKE_IDS" ] || exit 0
printf 'peer-relay-request%s\n' "$WAKE_IDS"
