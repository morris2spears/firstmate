#!/usr/bin/env bash
# Carbon-side peer-relay client and reply-pane delivery helper.
#
# Usage:
#   fm-peer-relay-tell.sh <message...>
#   fm-peer-relay-tell.sh --stdin
#   fm-peer-relay-tell.sh --deliver %<pane-id>   # reply body on stdin
#
# Sending captures the caller's exact tmux pane id, stable window id, session,
# hostname, and timestamp, then sends a versioned stdin envelope to mirage.
# Reply delivery types literal text once and submits it with a separate Enter.
#
# Configuration:
#   FMPEER_FIRSTMATE_HOST      SSH target (default: mirage)
#   FMPEER_RECEIVE_COMMAND     fixed remote command (default shown in --help)
#   FMPEER_SSH_BIN             SSH binary/test seam (default: ssh)
#   FMPEER_TMUX_BIN            tmux binary/test seam (default: tmux)
set -u

fmpeer_pane_id_valid() {
  local rest
  case "${1-}" in %*) rest=${1#%} ;; *) return 1 ;; esac
  case "$rest" in ''|*[!0-9]*) return 1 ;; esac
}

fmpeer_window_id_valid() {
  local rest
  case "${1-}" in @*) rest=${1#@} ;; *) return 1 ;; esac
  case "$rest" in ''|*[!0-9]*) return 1 ;; esac
}

fmpeer_session_name_valid() {
  case "${1-}" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

fmpeer_origin_host_valid() { [ "${1-}" = carbon ]; }

fmpeer_epoch_valid() {
  case "${1-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 18 ]
}

usage() {
  sed -n '2,18{s/^# \{0,1\}//;p;}' "$0"
  printf '%s\n' "Default remote command: FM_HOME=\$HOME/kun-agent-workspace \$HOME/kun-agent-workspace/bin/fm-peer-relay-receive.sh"
}

read_stdin_preserve() {  # <result-var>
  local result_var=$1 value
  value=$(cat; printf x)
  value=${value%x}
  printf -v "$result_var" '%s' "$value"
}

TMUX_BIN=${FMPEER_TMUX_BIN:-tmux}
if [ "${1-}" = --deliver ]; then
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  PANE=$2
  fmpeer_pane_id_valid "$PANE" || { echo 'error: invalid reply pane id' >&2; exit 2; }
  ACTUAL=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_id}' 2>/dev/null) \
    || { echo 'error: reply pane is unavailable' >&2; exit 1; }
  [ "$ACTUAL" = "$PANE" ] || { echo 'error: reply pane identity changed' >&2; exit 1; }
  read_stdin_preserve MESSAGE
  [ -n "$MESSAGE" ] || { echo 'error: empty peer relay reply' >&2; exit 2; }
  [ "${#MESSAGE}" -le 65536 ] || { echo 'error: peer relay reply exceeds 65536 bytes' >&2; exit 2; }
  "$TMUX_BIN" send-keys -t "$PANE" -l -- "$MESSAGE" \
    || { echo 'error: reply text was not delivered' >&2; exit 1; }
  "$TMUX_BIN" send-keys -t "$PANE" Enter \
    || { echo 'error: reply text may be present but Enter was not delivered' >&2; exit 1; }
  exit 0
fi

case "${1-}" in
  -h|--help|help) usage; exit 0 ;;
  --stdin)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_stdin_preserve MESSAGE
    ;;
  '') usage >&2; exit 2 ;;
  *) MESSAGE=$* ;;
esac
[ -n "$MESSAGE" ] || { echo 'error: peer relay message is empty' >&2; exit 2; }
[ "${#MESSAGE}" -le 65536 ] || { echo 'error: peer relay message exceeds 65536 bytes' >&2; exit 2; }

PANE=${TMUX_PANE:-}
fmpeer_pane_id_valid "$PANE" \
  || { echo 'error: peer relay must be called from the originating tmux pane' >&2; exit 1; }
IDENTITY=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_id}|#{session_name}|#{window_id}' 2>/dev/null) \
  || { echo 'error: cannot inspect originating tmux pane' >&2; exit 1; }
IFS='|' read -r ACTUAL_PANE SESSION WINDOW extra <<EOF
$IDENTITY
EOF
if [ -n "${extra:-}" ] || [ "$ACTUAL_PANE" != "$PANE" ] \
  || ! fmpeer_session_name_valid "$SESSION" || ! fmpeer_window_id_valid "$WINDOW"; then
  echo 'error: originating tmux identity is invalid' >&2
  exit 1
fi
ORIGIN=$(hostname -s 2>/dev/null) || { echo 'error: cannot read originating hostname' >&2; exit 1; }
fmpeer_origin_host_valid "$ORIGIN" \
  || { echo "error: this client currently accepts only the carbon peer (got $ORIGIN)" >&2; exit 1; }
CLIENT_EPOCH=$(date +%s)
fmpeer_epoch_valid "$CLIENT_EPOCH" || exit 1
SSH_BIN=${FMPEER_SSH_BIN:-ssh}
FIRSTMATE_HOST=${FMPEER_FIRSTMATE_HOST:-mirage}
# shellcheck disable=SC2016 # The remote shell, not this client, expands $HOME.
RECEIVE_COMMAND=${FMPEER_RECEIVE_COMMAND:-'FM_HOME=$HOME/kun-agent-workspace $HOME/kun-agent-workspace/bin/fm-peer-relay-receive.sh'}
{
  printf '%s\n' \
    fm-peer-relay-v1 \
    "origin_host=$ORIGIN" \
    "pane_id=$PANE" \
    "session_name=$SESSION" \
    "window_id=$WINDOW" \
    "client_epoch=$CLIENT_EPOCH" \
    ''
  printf '%s' "$MESSAGE"
} | "$SSH_BIN" -- "$FIRSTMATE_HOST" "$RECEIVE_COMMAND"
