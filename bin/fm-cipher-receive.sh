#!/usr/bin/env bash
# Receive Cipher's durable GitHub-comment pointer without resolving or writing to
# any terminal pane. Hermes calls this after its authenticated hook session has
# written the decision or production-outage blocker on GitHub.
#
# The command validates task, acknowledged request, event kind, canonical GitHub
# comment URL, and repository binding, then appends one idempotent check wake to
# the owning firstmate home's durable queue. Because delivery addresses FM_HOME
# state by task/request identity rather than scanning primary panes, a self-repo
# ship worker cannot be mistaken for a second primary, and the exactly-one-primary
# safety check used by terminal transports remains unchanged.
#
# Usage:
#   fm-cipher-receive.sh decision-comment <task-id> <request-id> <comment-url>
#   fm-cipher-receive.sh pr-blocker <task-id> <request-id> <comment-url>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PYTHON=${FM_CIPHER_PYTHON:-python3}
IMPLEMENTATION="$SCRIPT_DIR/fm-cipher-hook.py"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,15s/^# \{0,1\}//p' "$0"
}

[ "${1:-}" = -h ] || [ "${1:-}" = --help ] || [ "$#" -eq 4 ] || {
  usage >&2
  exit 2
}
if [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; then
  usage
  exit 0
fi
KIND=$1
ID=$2
REQUEST_ID=$3
COMMENT_URL=$4
case "$KIND" in
  decision-comment|pr-blocker) ;;
  *) echo "error: invalid Cipher receive request" >&2; exit 2 ;;
esac
command -v "$PYTHON" >/dev/null 2>&1 || {
  echo "error: Cipher receive requires python3" >&2
  exit 1
}

set +e
RECEIVE_ID=$("$PYTHON" "$IMPLEMENTATION" prepare-receive \
  "$KIND" "$ID" "$REQUEST_ID" "$COMMENT_URL")
PREPARE_RC=$?
set -e
case "$PREPARE_RC" in
  0) ;;
  3) exit 0 ;;
  *) exit "$PREPARE_RC" ;;
esac

fm_wake_append check "cipher-$RECEIVE_ID" \
  "cipher-comment $KIND $ID $REQUEST_ID $COMMENT_URL" || exit 1
# The queue is the payload authority. This append-only turn-end marker is only
# the content-free edge that makes a live watcher surface the already-durable
# record without selecting a primary pane or waiting for the slow-check cadence.
MARKER="$STATE/cipher-receive.turn-ended"
if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
  [ -f "$MARKER" ] && [ ! -L "$MARKER" ] \
    && [ "$(fm_pr_file_link_count "$MARKER")" = 1 ] || {
    echo "error: Cipher receive notification marker is unsafe" >&2
    exit 1
  }
fi
umask 077
printf '%s\n' "$RECEIVE_ID" >> "$MARKER" || exit 1
chmod 0600 "$MARKER" || exit 1
"$PYTHON" "$IMPLEMENTATION" commit-receive \
  "$KIND" "$ID" "$REQUEST_ID" "$COMMENT_URL" >/dev/null || exit 1
printf 'queued: %s\n' "$RECEIVE_ID"
