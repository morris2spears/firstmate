#!/usr/bin/env bash
# Deliver the two versioned, authenticated Cipher/Hermes transitions and provide
# Cipher's narrow exact-head entrypoint into the guarded iinvy merge path.
#
# `needs-decision` first proves that the named keyed decision remains open and
# current; `pr-ready` first proves the PR is genuinely checks-green - either
# current-state reconciliation reports it, or GitHub itself reports the pull
# request open and CLEAN, so a wedged or stale local CI monitor cannot hide a
# forge-green PR forever. The Python module receives only validated identity fields,
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
# `retry-held` is the watcher's recovery sweep for transiently held deliveries
# (gateway unavailable, timeout, transient HTTP). Each still-current held event
# re-enters its own preflighted trigger path, which adopts the recorded request
# so the exact body and request ID are retried with no duplicate delivery. It
# prints one line per delivered or superseded event and nothing while an event
# simply stays held; configuration-class holds are never auto-retried.
#
# `resolve-decision` durably closes the answered keyed status decision for an
# acknowledged needs-decision event. It refuses unless the authenticated
# decision-comment receive record for that exact request exists, then appends
# one idempotent "resolved [key=<decision-id>]: Cipher decision accepted
# <comment-url>" status line while the keyed decision is still open, so an
# answered decision cannot linger stale or keep held duplicates alive.
#
# `reconcile` is the watcher's checks-green reconciliation sweep. For every
# recorded gated GitHub pull request that is currently checks-green - by local
# reconciliation or by GitHub's own open-and-CLEAN answer - it re-registers
# through bin/fm-pr-check.sh - the one canonical trigger, which refreshes the
# exact head and re-enters this pr-ready path - so a green transition reached
# after registration (a rebase or sync, a repair or recovery, a manual
# coordinator reconciliation, a wedged local CI monitor) still emits its
# exact-head event durably instead of relying on agent prose. It prints one
# line per newly acknowledged event and nothing otherwise; a held current
# identity stays with `retry-held` or, for configuration-class holds, with
# captain repair.
#
# Usage:
#   fm-cipher-hook.sh needs-decision <task-id> [decision-id]
#   fm-cipher-hook.sh pr-ready <task-id> <pr-url>
#   fm-cipher-hook.sh retry-held
#   fm-cipher-hook.sh resolve-decision <task-id> <request-id>
#   fm-cipher-hook.sh reconcile
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
  sed -n '2,62s/^# \{0,1\}//p' "$0"
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

# Checks-green means local reconciliation reports it OR the forge itself does.
# Local run-step state is the cheap primary read, but it can under-report while
# the pipeline's own CI monitor is wedged or stale, so GitHub's own answer is
# accepted as equal truth before an event is refused or skipped. That forge
# answer is deliberately strict - open, CLEAN, and a check rollup carrying a
# real passed check - so a pull request whose CI has not run cannot pass as
# green here (see fm_pr_github_snapshot in bin/fm-pr-lib.sh).
pr_checks_green_now() { # <current-state-line> <pr-url>
  case "$1" in
    "state: done"*"checks green"*) return 0 ;;
  esac
  fm_pr_github_checks_green "$2"
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
  resolve-decision)
    [ "$#" -eq 3 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    ID=$2
    REQUEST_ID=$3
    if ! fm_task_id_creation_valid "$ID"; then
      echo "error: invalid Cipher hook request" >&2
      exit 2
    fi
    PLAN=$(run_python resolve-decision "$ID" "$REQUEST_ID") || exit 1
    read -r DECISION COMMENT_URL <<<"$PLAN"
    if [ -z "${DECISION:-}" ] || [ -z "${COMMENT_URL:-}" ]; then
      echo "error: invalid Cipher hook request" >&2
      exit 2
    fi
    # Idempotent: a decision already closed (or a retired status record) needs
    # no second resolution line.
    decision_is_open "$ID" "$DECISION" || exit 0
    printf 'resolved [key=%s]: Cipher decision accepted %s\n' \
      "$DECISION" "$COMMENT_URL" >> "$STATE/$ID.status" || exit 1
    printf 'resolved %s %s\n' "$ID" "$DECISION"
    exit 0
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
    pr_checks_green_now "$STATE_LINE" "$URL" || exit 4
    run_python deliver iinvy-pr-ready "$ID" "$URL"
    exit $?
    ;;
  retry-held)
    [ "$#" -eq 1 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    [ -d "$STATE/cipher-hooks/holds" ] || exit 0
    PLAN=$(run_python retry-plan) || exit 1
    [ -n "$PLAN" ] || exit 0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        superseded\ *)
          printf '%s\n' "$line"
          continue
          ;;
        retry\ *) ;;
        *) continue ;;
      esac
      read -r _ REQUEST_ID KIND ID ARGUMENT <<<"$line"
      [ -n "${ARGUMENT:-}" ] || continue
      STATE_LINE=$(current_state "$ID")
      case "$KIND" in
        needs-decision)
          case "$STATE_LINE" in
            "state: parked"*) DECISION_CURRENT=1 ;;
            *) DECISION_CURRENT=0 ;;
          esac
          if [ "$DECISION_CURRENT" -eq 1 ] && decision_is_open "$ID" "$ARGUMENT"; then
            if FM_CIPHER_RETRIES=1 run_python deliver needs-decision "$ID" "$ARGUMENT"; then
              printf 'delivered %s needs-decision %s\n' "$REQUEST_ID" "$ID"
            fi
          elif run_python supersede "$REQUEST_ID" decision-closed; then
            printf 'superseded %s (decision-closed)\n' "$REQUEST_ID"
          fi
          ;;
        iinvy-pr-ready)
          # Deliberately asymmetric with needs-decision: a not-green state is
          # never a supersede here. Checks can regress and come back green on
          # the SAME head, which keeps the same request identity, so killing
          # the event on a temporarily not-green read would drop a delivery
          # that must still retry. A merged or declined pull request instead
          # supersedes once teardown removes the task metadata.
          if pr_checks_green_now "$STATE_LINE" "$ARGUMENT"; then
            if FM_CIPHER_RETRIES=1 run_python deliver iinvy-pr-ready "$ID" "$ARGUMENT"; then
              printf 'delivered %s iinvy-pr-ready %s\n' "$REQUEST_ID" "$ID"
            fi
          fi
          ;;
      esac
    done <<EOF
$PLAN
EOF
    exit 0
    ;;
  reconcile)
    [ "$#" -eq 1 ] || { echo "error: invalid Cipher hook request" >&2; exit 2; }
    ACKS="$STATE/cipher-hooks/acks"
    HOLDS="$STATE/cipher-hooks/holds"
    ANNOUNCED="$STATE/cipher-hooks/announced"
    # The sweep runs on the watcher's own cadence, so bin/fm-pr-check.sh is
    # invoked here by a descendant of the watcher rather than by an agent or
    # coordinator. Its migration takes watcher exclusion by terminating the
    # live watcher, which would be this process's own ancestor, so the
    # watcher-internal path asks the migration to defer instead. An un-migrated
    # home simply reconciles on a later cadence, after a coordinator-run
    # bin/fm-pr-check.sh has crossed that boundary safely.
    export FM_PR_CHECK_MIGRATION_DEFER=1
    # An announcement is durable, not in-process: the check that prints it can
    # be killed by the watcher's check timeout after the acknowledgement is
    # already written, and diffing the acks directory in memory would then
    # leave that PR-ready silently unannounced forever. A task the sweep is
    # about to register is marked pending first and unmarked as soon as that
    # iteration reaches any outcome of its own, so the marker outlives the
    # iteration only when the sweep was killed inside the delivery window and
    # a later cadence still owes the announcement. An acknowledgement the
    # sweep never registered was already reported by its own registration or
    # by the retry-held sweep, so it is recorded as announced without a wake
    # and steady state stays silent.
    marker_path() { # <name>
      case "$1" in
        *[!A-Za-z0-9._-]*|''|.|..) return 1 ;;
      esac
      printf '%s/%s\n' "$ANNOUNCED" "$1"
    }
    mark_announced() { # <name>
      local file
      file=$(marker_path "$1") || return 0
      (umask 077 && mkdir -p "$ANNOUNCED" && : > "$file") 2>/dev/null || true
      return 0
    }
    clear_marker() { # <name>
      local file
      file=$(marker_path "$1") || return 0
      rm -f -- "$file" 2>/dev/null || true
      return 0
    }
    announce_reconciled() { # <request-id> <task-id>
      local rid=$1 id=$2 file
      file=$(marker_path "$rid") || { clear_marker "$id.pending"; return 0; }
      if [ ! -f "$file" ]; then
        printf 'delivered %s iinvy-pr-ready %s\n' "$rid" "$id"
        mark_announced "$rid"
      fi
      clear_marker "$id.pending"
      return 0
    }
    # The announcement set is bounded by the bridge's own durable record set
    # rather than pruned on a schedule of its own: a request marker is written
    # only beside an acknowledgement, so the markers can never outnumber the
    # acknowledgements they mirror and they retire with them. A marker whose
    # acknowledgement or whose task metadata is already gone describes nothing
    # and is dropped here, which is what keeps an interrupted announcement from
    # outliving its task.
    prune_markers() {
      local file name
      [ -d "$ANNOUNCED" ] || return 0
      for file in "$ANNOUNCED"/*; do
        [ -f "$file" ] || continue
        name=$(basename "$file")
        case "$name" in
          *.pending)
            [ -f "$STATE/${name%.pending}.meta" ] || rm -f -- "$file" 2>/dev/null || true
            ;;
          *)
            [ -f "$ACKS/$name.json" ] || rm -f -- "$file" 2>/dev/null || true
            ;;
        esac
      done
      return 0
    }
    reconcile_task() { # <task-id> <pr-url>
      local ID=$1 URL=$2 META="$STATE/$1.meta"
      local WORKTREE LIVE_HEAD STATE_LINE RECORDED_HEAD RID
      [ -f "$META" ] && [ ! -L "$META" ] || return 0
      # One forge round-trip answers both questions this sweep asks of a gated
      # pull request - is it green, and where is its head now - inside a check
      # budget shared with every other task in the glob.
      WORKTREE=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2-)
      fm_pr_github_snapshot "$WORKTREE" "$URL"
      LIVE_HEAD=$FM_PR_GITHUB_HEAD
      STATE_LINE=$(current_state "$ID")
      case "$STATE_LINE" in
        "state: done"*"checks green"*) ;;
        *) [ "$FM_PR_GITHUB_GREEN" = 1 ] || return 0 ;;
      esac
      RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2-)
      RID=$(run_python request-id "$ID" "$URL" 2>/dev/null) || RID=
      if [ -z "$LIVE_HEAD" ] || [ "$LIVE_HEAD" = "$RECORDED_HEAD" ]; then
        # Same or unknown live head: an acknowledged current identity is
        # complete and only needs its announcement to be durable, and a held
        # one belongs to retry-held or captain repair. Only a live head that
        # moved past the recorded one re-registers regardless, so a post-hold
        # rebase still gets its fresh event.
        if [ -n "$RID" ] && [ -f "$ACKS/$RID.json" ]; then
          if [ -f "$ANNOUNCED/$ID.pending" ]; then
            announce_reconciled "$RID" "$ID"
          else
            mark_announced "$RID"
          fi
          return 0
        fi
        if [ -n "$RID" ] && [ -f "$HOLDS/$RID.json" ]; then
          clear_marker "$ID.pending"
          return 0
        fi
      fi
      mark_announced "$ID.pending"
      "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" >/dev/null 2>&1 || true
      RID=$(run_python request-id "$ID" "$URL" 2>/dev/null) || RID=
      if [ -n "$RID" ] && [ -f "$ACKS/$RID.json" ]; then
        announce_reconciled "$RID" "$ID"
      else
        clear_marker "$ID.pending"
      fi
      return 0
    }
    # Selecting the gated pull requests costs no forge call, so the whole
    # inventory is always known; only the per-task forge work is bounded. The
    # watcher runs this sweep under a check timeout, and an unbounded sweep
    # killed by it would restart at the same alphabetical head every cadence
    # and never reach the later tasks - the very class of missed transition
    # this sweep exists to close. So the sweep resumes where the last one
    # stopped and takes at most a fixed number of tasks per cadence, and it
    # records each task as taken before spending the round trip, so even a task
    # whose own iteration is killed cannot pin the cursor and starve the rest.
    RECONCILE_IDS=()
    RECONCILE_URLS=()
    for META in "$STATE"/*.meta; do
      [ -f "$META" ] && [ ! -L "$META" ] || continue
      ID=$(basename "$META" .meta)
      fm_task_id_creation_valid "$ID" || continue
      URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2-)
      [ -n "$URL" ] || continue
      fm_pr_url_parse "$URL" || continue
      [ "$FM_PR_PROVIDER" = github ] || continue
      fm_cipher_repo_gated "$FM_PR_PATH" || continue
      RECONCILE_IDS+=("$ID")
      RECONCILE_URLS+=("$URL")
    done
    TOTAL=${#RECONCILE_IDS[@]}
    if [ "$TOTAL" -gt 0 ]; then
      # Sweep bookkeeping, never a Cipher record, so it lives beside the task
      # state rather than inside the private cipher-hooks record tree, which
      # exists only once a real event does.
      CURSOR="$STATE/.cipher-reconcile-cursor"
      BUDGET=${FM_CIPHER_RECONCILE_BUDGET:-8}
      case "$BUDGET" in
        ''|*[!0-9]*|0) BUDGET=8 ;;
      esac
      LAST=
      [ ! -f "$CURSOR" ] || LAST=$(head -1 "$CURSOR" 2>/dev/null) || LAST=
      START=0
      INDEX=0
      while [ "$INDEX" -lt "$TOTAL" ]; do
        if [ "${RECONCILE_IDS[$INDEX]}" = "$LAST" ]; then
          START=$(( (INDEX + 1) % TOTAL ))
          break
        fi
        INDEX=$((INDEX + 1))
      done
      TAKEN=0
      while [ "$TAKEN" -lt "$TOTAL" ] && [ "$TAKEN" -lt "$BUDGET" ]; do
        INDEX=$(( (START + TAKEN) % TOTAL ))
        TAKEN=$((TAKEN + 1))
        ID=${RECONCILE_IDS[$INDEX]}
        (umask 077 && printf '%s\n' "$ID" > "$CURSOR") 2>/dev/null || true
        reconcile_task "$ID" "${RECONCILE_URLS[$INDEX]}"
      done
    fi
    prune_markers
    exit 0
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
