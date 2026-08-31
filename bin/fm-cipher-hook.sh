#!/usr/bin/env bash
# Deliver the two versioned, authenticated Cipher/Hermes transitions and provide
# Cipher's narrow exact-head entrypoint into the guarded iinvy merge path.
#
# `needs-decision` first proves that the named keyed decision remains open and
# current; `pr-ready` first proves that current-state reconciliation reports a
# checks-green PR. The Python module receives only validated identity fields,
# never worker prose. It owns strict payload/config validation, HMAC-SHA256 over
# the exact request bytes, stable request IDs, private request/sent/ack/hold
# records under state/cipher-hooks/, bounded retry, and localhost transport.
# Production sends Hermes generic HMAC V2 over `<timestamp>.<exact-body>` in
# X-Webhook-Signature-V2 plus X-Webhook-Timestamp, with the stable identity in
# X-Request-ID. The body-only V1 header exists only when both test-only
# FM_CIPHER_SIGNATURE_VERSION=legacy-v1 and FM_CIPHER_ALLOW_LEGACY_V1_TEST=1.
#
# An absent or explicitly disabled decision route exits 3 without changing the
# existing decision authority. A gated PR that is not currently green exits 4
# without delivery so ordinary PR registration can continue waiting for checks.
# The iinvy PR-ready route otherwise refuses on every
# missing, disabled, malformed, unavailable, timed-out, or invalid-response case.
# Only Cipher invokes `merge`; firstmate's ordinary merge command is separately
# guarded and accepts an iinvy merge only with this event's acknowledged request
# identity, while GitHub's exact-head condition prevents a later head from riding
# an earlier inspection.
#
# Usage:
#   fm-cipher-hook.sh needs-decision <task-id> [decision-id]
#   fm-cipher-hook.sh pr-ready <task-id> <pr-url>
#   fm-cipher-hook.sh merge <task-id> <pr-url> <request-id> [-- <extra merge args>]
#   fm-cipher-hook.sh verify-merge <task-id> <pr-url> <request-id>
#   fm-cipher-hook.sh repo-gated <owner/repo>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PYTHON=${FM_CIPHER_PYTHON:-python3}
IMPLEMENTATION="$SCRIPT_DIR/fm-cipher-hook.py"
CREW_STATE_BIN=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  sed -n '2,31s/^# \{0,1\}//p' "$0"
}

run_python() {
  command -v "$PYTHON" >/dev/null 2>&1 || {
    echo "error: Cipher hooks require python3" >&2
    return 1
  }
  "$PYTHON" "$IMPLEMENTATION" "$@"
}

current_state() { # <task-id>
  "$CREW_STATE_BIN" "$1" 2>/dev/null || true
}

decision_is_open() { # <task-id> <decision-id>
  local id=$1 decision=$2 row key verb rest
  [ -f "$STATE/$id.status" ] && [ ! -L "$STATE/$id.status" ] || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    key=${row%%$'\t'*}
    rest=${row#*$'\t'}
    verb=${rest%%$'\t'*}
    if [ "$key" = "$decision" ] && [ "$verb" = needs-decision ]; then
      return 0
    fi
  done < <(status_open_decisions "$STATE/$id.status")
  return 1
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  repo-gated)
    [ "$#" -eq 2 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    fm_cipher_repo_gated "$2"
    exit $?
    ;;
  needs-decision)
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    ID=$2
    DECISION=${3:-default}
    if ! fm_task_id_creation_valid "$ID"; then
      echo "error: invalid Cipher hook request" >&2
      exit 2
    fi
    case "$DECISION" in
      ''|.|..|*[!A-Za-z0-9._-]*) echo "error: invalid Cipher hook request" >&2; exit 2 ;;
    esac
    [ "${#DECISION}" -le 64 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    STATE_LINE=$(current_state "$ID")
    case "$STATE_LINE" in
      "state: parked"*) ;;
      *) echo "error: Cipher hook refused: task is not at a current decision" >&2; exit 1 ;;
    esac
    decision_is_open "$ID" "$DECISION" || {
      echo "error: Cipher hook refused: named decision is not open" >&2
      exit 1
    }
    run_python deliver needs-decision "$ID" "$DECISION"
    exit $?
    ;;
  pr-ready)
    [ "$#" -eq 3 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    ID=$2
    URL=$3
    if ! fm_task_id_creation_valid "$ID" || ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
      echo "error: invalid Cipher hook request" >&2
      exit 2
    fi
    run_python repo-gated "$FM_PR_PATH" || {
      echo "error: Cipher hook refused: repository is not an iinvy production gate" >&2
      exit 2
    }
    STATE_LINE=$(current_state "$ID")
    case "$STATE_LINE" in
      "state: done"*"checks green"*) ;;
      *) exit 4 ;;
    esac
    run_python deliver iinvy-pr-ready "$ID" "$URL"
    exit $?
    ;;
  verify-merge)
    [ "$#" -eq 4 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    run_python verify-merge "$2" "$3" "$4"
    exit $?
    ;;
  merge)
    [ "$#" -ge 4 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    ID=$2
    URL=$3
    REQUEST_ID=$4
    shift 4
    [ "${1:-}" = -- ] && shift
    # Refresh canonical PR metadata and emit a new exact-head event if the PR
    # advanced after Cipher's inspection. The caller must still present the
    # request identity it inspected, so a newly acknowledged replacement event
    # stops here instead of letting the old inspection merge the new head.
    "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" || exit 1
    run_python verify-merge "$ID" "$URL" "$REQUEST_ID" >/dev/null || exit 1
    FM_CIPHER_MERGE_REQUEST_ID=$REQUEST_ID \
      exec "$SCRIPT_DIR/fm-pr-merge.sh" "$ID" "$URL" -- "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
