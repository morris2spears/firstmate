#!/usr/bin/env bash
# Inspect or answer one durable peer-relay request.
#
# Usage:
#   fm-peer-relay-reply.sh inspect <request-id>
#   fm-peer-relay-reply.sh send <request-id> --text-file <path|->
#
# send records the reply and state=sending before SSH. A confirmed zero exit
# marks resolved; any other result marks delivery-uncertain and refuses blind
# retry because the text or Enter may already have reached the carbon pane.
# FMPEER_SSH_BIN and FMPEER_REMOTE_CLIENT are transport test/config seams.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo 'error: FM_HOME must be set explicitly' >&2
  exit 2
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-peer-relay-lib.sh
. "$SCRIPT_DIR/fm-peer-relay-lib.sh"

usage() {
  sed -n '2,10{s/^# \{0,1\}//;p;}' "$0"
}

COMMAND=${1-}
case "$COMMAND" in
  -h|--help|help) usage; exit 0 ;;
esac
REQUEST_ID=${2-}
fmpeer_request_id_valid "$REQUEST_ID" || { usage >&2; exit 2; }
REQUEST_DIR=$(fmpeer_request_dir "$STATE" "$REQUEST_ID") || exit 2
fmpeer_request_dir_valid "$STATE" "$REQUEST_ID" \
  || { echo 'error: peer relay request is unavailable or unsafe' >&2; exit 1; }

case "$COMMAND" in
  inspect)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    cat "$REQUEST_DIR/meta" "$REQUEST_DIR/status"
    printf '%s\n' '--- message ---'
    cat "$REQUEST_DIR/message"
    ;;
  send)
    [ "$#" -eq 4 ] && [ "${3-}" = --text-file ] \
      || { usage >&2; exit 2; }
    STATUS=$(fmpeer_status_get "$REQUEST_DIR")
    [ "$STATUS" = pending ] \
      || { echo "error: peer relay request is $STATUS; send is allowed only while pending" >&2; exit 1; }
    ORIGIN=$(fmpeer_meta_get "$REQUEST_DIR" origin_host)
    PANE=$(fmpeer_meta_get "$REQUEST_DIR" pane_id)
    if ! fmpeer_origin_host_valid "$ORIGIN" || ! fmpeer_pane_id_valid "$PANE"; then
      echo 'error: peer relay reply target is invalid' >&2
      exit 1
    fi
    REPLY_SOURCE=$4
    INPUT_TMP=$(umask 077; mktemp "$REQUEST_DIR/.reply.input.XXXXXX") || exit 1
    # shellcheck disable=SC2329 # Invoked by the EXIT trap below.
    cleanup_reply_input() { [ -z "${INPUT_TMP:-}" ] || rm -f -- "$INPUT_TMP"; }
    trap cleanup_reply_input EXIT
    if [ "$REPLY_SOURCE" = - ]; then
      cat > "$INPUT_TMP" || exit 1
    else
      [ -f "$REPLY_SOURCE" ] && [ ! -L "$REPLY_SOURCE" ] \
        || { echo 'error: reply text file is unavailable or unsafe' >&2; exit 2; }
      cat "$REPLY_SOURCE" > "$INPUT_TMP" || exit 1
    fi
    chmod 0600 "$INPUT_TMP" || exit 1
    REPLY_SIZE=$(wc -c < "$INPUT_TMP" | tr -d ' ')
    case "$REPLY_SIZE" in
      ''|*[!0-9]*) exit 1 ;;
    esac
    if [ "$REPLY_SIZE" -eq 0 ] || [ "$REPLY_SIZE" -gt 65536 ]; then
      echo 'error: reply must contain 1 through 65536 bytes' >&2
      exit 2
    fi
    if ! fmx_private_artifact_publish_stdin "$REQUEST_DIR" reply 600 < "$INPUT_TMP"; then
      echo 'error: cannot record peer relay reply' >&2
      exit 1
    fi
    rm -f -- "$INPUT_TMP"
    INPUT_TMP=
    NOW=${FMPEER_NOW_OVERRIDE:-$(date +%s)}
    fmpeer_epoch_valid "$NOW" || { echo 'error: invalid reply timestamp' >&2; exit 1; }
    fmpeer_status_write "$REQUEST_DIR" sending "$NOW" \
      || { echo 'error: cannot mark peer relay reply sending' >&2; exit 1; }

    SSH_BIN=${FMPEER_SSH_BIN:-ssh}
    REMOTE_CLIENT=${FMPEER_REMOTE_CLIENT:-}
    # Default is expanded by the remote login shell, so it stays portable
    # across peer accounts instead of pinning one operator's home path.
    # shellcheck disable=SC2088 # The remote login shell expands this tilde, not us.
    [ -n "$REMOTE_CLIENT" ] || REMOTE_CLIENT='~/.local/bin/fm-peer-relay-tell.sh'
    "$SSH_BIN" -- "$ORIGIN" "$REMOTE_CLIENT" --deliver "$PANE" < "$REQUEST_DIR/reply"
    rc=$?
    FINISHED=${FMPEER_NOW_OVERRIDE:-$(date +%s)}
    fmpeer_epoch_valid "$FINISHED" || FINISHED=$NOW
    if [ "$rc" -eq 0 ]; then
      fmpeer_status_write "$REQUEST_DIR" resolved "$FINISHED" \
        || { echo 'error: reply delivered but resolved state could not be recorded' >&2; exit 1; }
      OFFERED=$(fmpeer_offered_dir "$STATE")
      if fmx_private_artifact_dir_device "$OFFERED" >/dev/null 2>&1; then
        rm -f -- "$OFFERED/$REQUEST_ID" 2>/dev/null || true
      fi
      printf 'resolved %s\n' "$REQUEST_ID"
      exit 0
    fi
    fmpeer_status_write "$REQUEST_DIR" delivery-uncertain "$FINISHED" \
      || echo 'error: reply delivery and uncertainty recording both failed' >&2
    echo 'error: reply delivery is uncertain; inspect the carbon pane before any retry' >&2
    exit "$rc"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
