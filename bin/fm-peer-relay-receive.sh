#!/usr/bin/env bash
# Receive one trusted carbon peer request on stdin, publish it durably, and make
# the authenticated peer-relay check due on the active Firstmate watcher.
#
# Remote wire format (stdin):
#   fm-peer-relay-v1
#   origin_host=carbon
#   pane_id=%<digits>
#   session_name=<safe tmux session name>
#   window_id=@<digits>
#   client_epoch=<epoch>
#   <blank line>
#   <raw captain message, up to 65536 bytes>
#
# Requires an explicit absolute FM_HOME, config/peer-relay-carbon, an SSH
# connection, and the bootstrap-generated registered peer-relay check.
# FMPEER_TEST_ALLOW_LOCAL=1 is a test-only seam for hermetic invocation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  FM_HOME=/absolute/firstmate/home bin/fm-peer-relay-receive.sh < envelope

The caller normally uses fm-peer-relay-tell.sh on carbon, which constructs the
versioned envelope and invokes this command over SSH to mirage.
EOF
}

case "${1-}" in
  -h|--help|help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo 'error: FM_HOME must be set explicitly' >&2
  exit 2
fi
case "$FM_HOME" in
  /*) ;;
  *) echo 'error: FM_HOME must be absolute' >&2; exit 2 ;;
esac
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-peer-relay-lib.sh
. "$SCRIPT_DIR/fm-peer-relay-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

fmpeer_enabled "$FM_HOME" || { echo 'error: peer relay is not enabled for this home' >&2; exit 1; }
if [ -z "${SSH_CONNECTION:-}" ] && [ "${FMPEER_TEST_ALLOW_LOCAL:-0}" != 1 ]; then
  echo 'error: peer relay receive is accepted only through SSH' >&2
  exit 1
fi
CHECK_ID=$FMPEER_CHECK_ID
if ! fm_custom_check_registered "$STATE" "$CHECK_ID"; then
  echo 'error: peer relay watcher check is not registered; run bin/fm-bootstrap.sh in the primary home' >&2
  exit 1
fi

read_line() {
  IFS= read -r "$1" || { echo 'error: incomplete peer relay envelope' >&2; exit 2; }
}

protocol=
origin_line=
pane_line=
session_line=
window_line=
epoch_line=
separator=
read_line protocol
read_line origin_line
read_line pane_line
read_line session_line
read_line window_line
read_line epoch_line
read_line separator
[ "$protocol" = fm-peer-relay-v1 ] || { echo 'error: unsupported peer relay protocol' >&2; exit 2; }
[ -z "$separator" ] || { echo 'error: malformed peer relay envelope' >&2; exit 2; }
ORIGIN=${origin_line#origin_host=}
PANE=${pane_line#pane_id=}
SESSION=${session_line#session_name=}
WINDOW=${window_line#window_id=}
CLIENT_EPOCH=${epoch_line#client_epoch=}
if [ "$ORIGIN" = "$origin_line" ] || ! fmpeer_origin_host_valid "$ORIGIN"; then
  echo 'error: invalid peer origin' >&2
  exit 2
fi
if [ "$PANE" = "$pane_line" ] || ! fmpeer_pane_id_valid "$PANE"; then
  echo 'error: invalid peer pane id' >&2
  exit 2
fi
if [ "$SESSION" = "$session_line" ] || ! fmpeer_session_name_valid "$SESSION"; then
  echo 'error: invalid peer session name' >&2
  exit 2
fi
if [ "$WINDOW" = "$window_line" ] || ! fmpeer_window_id_valid "$WINDOW"; then
  echo 'error: invalid peer window id' >&2
  exit 2
fi
if [ "$CLIENT_EPOCH" = "$epoch_line" ] || ! fmpeer_epoch_valid "$CLIENT_EPOCH"; then
  echo 'error: invalid peer timestamp' >&2
  exit 2
fi

STORE=$(fmpeer_store_dir "$STATE")
fmx_private_artifact_dir_prepare "$STORE" >/dev/null \
  || { echo 'error: peer relay request store is unavailable' >&2; exit 1; }
STAGE=$(umask 077; mktemp -d "$STORE/.incoming.XXXXXX") \
  || { echo 'error: cannot stage peer relay request' >&2; exit 1; }
cleanup() {
  [ -z "${STAGE:-}" ] || rm -rf -- "$STAGE"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 0700 "$STAGE" || exit 1
# Bounded ingest: read one byte past the documented cap so an oversized or
# runaway stream is rejected below without ever landing in full on this home.
head -c 65537 > "$STAGE/message" || exit 1
chmod 0600 "$STAGE/message" || exit 1
SIZE=$(wc -c < "$STAGE/message" | tr -d ' ')
case "$SIZE" in
  ''|*[!0-9]*) echo 'error: cannot size peer relay message' >&2; exit 1 ;;
esac
[ "$SIZE" -gt 0 ] || { echo 'error: peer relay message is empty' >&2; exit 2; }
[ "$SIZE" -le 65536 ] || { echo 'error: peer relay message exceeds 65536 bytes' >&2; exit 2; }

RECEIVED_EPOCH=${FMPEER_NOW_OVERRIDE:-$(date +%s)}
fmpeer_epoch_valid "$RECEIVED_EPOCH" || { echo 'error: invalid receive timestamp' >&2; exit 1; }
SUFFIX=${STAGE##*.incoming.}
REQUEST_ID="peer-${RECEIVED_EPOCH}-${SUFFIX}"
fmpeer_request_id_valid "$REQUEST_ID" || { echo 'error: cannot generate peer relay request id' >&2; exit 1; }
cat > "$STAGE/meta" <<EOF
version=1
request_id=$REQUEST_ID
origin_host=$ORIGIN
pane_id=$PANE
session_name=$SESSION
window_id=$WINDOW
client_epoch=$CLIENT_EPOCH
received_epoch=$RECEIVED_EPOCH
EOF
printf 'state=pending\nupdated_epoch=%s\n' "$RECEIVED_EPOCH" > "$STAGE/status"
chmod 0600 "$STAGE/meta" "$STAGE/status" || exit 1
DEST="$STORE/$REQUEST_ID"
[ ! -e "$DEST" ] && [ ! -L "$DEST" ] || { echo 'error: peer relay request id collision' >&2; exit 1; }
mv -- "$STAGE" "$DEST" || { echo 'error: cannot publish peer relay request' >&2; exit 1; }
STAGE=
fmpeer_request_dir_valid "$STATE" "$REQUEST_ID" \
  || { echo 'error: published peer relay request failed validation' >&2; exit 1; }

# The watcher owns durable check-wake publication. Removing only its cadence
# marker makes the authenticated peer poll due on the next ordinary watcher tick.
rm -f -- "$STATE/.last-check" 2>/dev/null || true
printf '%s\n' "$REQUEST_ID"
