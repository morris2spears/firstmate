#!/usr/bin/env bash
# fm-afk-return.sh - deterministic away-mode return catch-up gate.
#
# Usage:
#   fm-afk-return.sh          Stop away mode, drain catch-up, and open/check gate.
#   fm-afk-return.sh begin    Same as the default command.
#   fm-afk-return.sh check    Re-drain and close the gate only after blockers resolve.
#   fm-afk-return.sh guard    Read-only refusal while away or catch-up is pending.
#
# `blocked:` is the crewmate protocol's firstmate-actionable verb. A live task's
# open blocked event must be remediated and closed with `resolved [key=...]`, or
# explicitly reclassified in the status stream with a durable reason, before an
# ordinary captain request may proceed. `needs-decision:` belongs to the
# configured approval authority and is deliberately not part of this blocker
# gate; normal reporting routes it through the AGENTS.md section 7 contract.
#
# The durable state/.afk-return-catchup file is written BEFORE daemon shutdown,
# so a crash between stopping, draining, and blocker handling fails closed. It
# retains the drained wake, buffered-escalation, and wedge-marker evidence until
# every live open blocker is closed and `check` succeeds. Repeated begin/check
# calls are idempotent. `guard` never mutates state and is suitable for ordinary
# read entrypoints such as fm-bearings-snapshot.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GATE="$STATE/.afk-return-catchup"
# The away batch ledger owner: the return path folds and retires the away records
# through it rather than deleting them itself.
# shellcheck source=bin/fm-away-ledger-lib.sh
. "$SCRIPT_DIR/fm-away-ledger-lib.sh"
LOCK="$STATE/.afk-return-catchup.lock"

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

append_evidence() {  # <kind> <text> <file>
  local kind=$1 text=$2 file=$3 clean record
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    clean=$(printf '%s' "$line" | clean_field)
    record=$(printf 'evidence\t%s\t%s' "$kind" "$clean")
    grep -Fqx "$record" "$file" 2>/dev/null || printf '%s\n' "$record" >> "$file"
  done <<EOF
$text
EOF
}

preserve_evidence() {  # <destination>
  local destination=$1
  [ -f "$GATE" ] || return 0
  grep '^evidence'"$(printf '\t')" "$GATE" >> "$destination" 2>/dev/null || true
}

scan_open_blockers() {  # -> tab-separated blocker rows
  local meta id status key verb summary clean_summary
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    status="$STATE/$id.status"
    [ -f "$status" ] || continue
    while IFS="$(printf '\t')" read -r key verb summary; do
      [ "$verb" = blocked ] || continue
      clean_summary=$(printf '%s' "$summary" | clean_field)
      printf 'blocker\t%s\t%s\t%s\n' "$id" "$key" "$clean_summary"
    done <<EOF
$(status_open_decisions "$status")
EOF
  done
}

write_pending_seed() {  # Fail-closed marker before any lifecycle mutation.
  local pending started
  mkdir -p "$STATE" || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  {
    printf 'schema\tfm-afk-return.v1\n'
    printf 'started\t%s\n' "$started"
    printf 'phase\tstopping-and-draining\n'
    preserve_evidence /dev/stdout
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

write_gate() {  # <evidence-file> <blockers-file>
  local evidence=$1 blockers=$2 pending started
  pending=$(mktemp "$STATE/.afk-return-catchup.pending.XXXXXX") || return 1
  started=$(awk -F '\t' '$1 == "started" { print $2; exit }' "$GATE" 2>/dev/null || true)
  [ -n "$started" ] || started=$(date +%s)
  {
    printf 'schema\tfm-afk-return.v1\n'
    printf 'started\t%s\n' "$started"
    printf 'phase\tblocked\n'
    cat "$evidence" 2>/dev/null || true
    cat "$blockers" 2>/dev/null || true
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$GATE"
}

print_evidence() {  # <file>
  local file=$1 kind text
  while IFS="$(printf '\t')" read -r tag kind text; do
    [ "$tag" = evidence ] || continue
    printf 'catch-up %s: %s\n' "$kind" "$text"
  done < "$file"
}

print_blockers() {  # <file>
  local file=$1 tag id key summary
  while IFS="$(printf '\t')" read -r tag id key summary; do
    [ "$tag" = blocker ] || continue
    printf 'firstmate-actionable blocker: %s [key=%s] %s\n' "$id" "$key" "$summary"
  done < "$file"
}

clear_delivery_artifacts() {
  # Retire the complete owned unit through the ledger owner. Only ever called
  # after the catch-up evidence above has folded the digests in, so an accepted
  # one-shot escalation is never dropped here. The text-free <id>.status
  # delivery evidence is deliberately kept.
  away_ledger_retire_batch "$STATE" "$STATE/.subsuper-escalations" \
    "$STATE/.subsuper-inject-wedged"
}

return_guard() {
  if [ -e "$STATE/.afk" ]; then
    printf 'fm-afk-return: away mode is still active; run bin/fm-afk-return.sh before ordinary captain work\n' >&2
    return 3
  fi
  if [ -e "$GATE" ]; then
    printf 'fm-afk-return: return catch-up is pending; remediate or durably reclassify every listed blocker, then run bin/fm-afk-return.sh check\n' >&2
    print_blockers "$GATE" >&2
    return 3
  fi
  return 0
}

return_reconcile() {
  local evidence blockers drained wedge escalations away_items retained lifecycle_ok=1 reclaim_rc=0
  evidence=$(mktemp "$STATE/.afk-return-evidence.XXXXXX") || return 1
  blockers=$(mktemp "$STATE/.afk-return-blockers.XXXXXX") || { rm -f "$evidence"; return 1; }
  preserve_evidence "$evidence"

  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-daemon-terminal" ]; then
    if ! "$SCRIPT_DIR/fm-afk-launch.sh" stop; then
      lifecycle_ok=0
      append_evidence lifecycle 'away-mode shutdown failed; lifecycle state preserved for retry' "$evidence"
    fi
  fi

  drained=$("$SCRIPT_DIR/fm-wake-drain.sh") || {
    append_evidence lifecycle 'durable wake drain failed; retry catch-up before ordinary work' "$evidence"
    lifecycle_ok=0
    drained=""
  }
  append_evidence wake "$drained" "$evidence"

  # Reclaim any complete buffer/sidecar/wedge group (and any digest text,
  # unconditionally) stranded in a leftover launch-rollback backup BEFORE the
  # live-unit evidence below is gathered, so an adopted group (only possible
  # when the live unit was clear) is captured by those reads in this same pass
  # instead of being adopted and then destroyed by clear_delivery_artifacts
  # with no evidence ever recorded. rc 2 means only a live conflict deferred a
  # backup's group - the normal wait state, not a fault - so only rc 1 (a real
  # copy/prepare/removal failure) is worth surfacing.
  away_ledger_reclaim_backups "$STATE" "$STATE/.subsuper-escalations" \
    "$STATE/.subsuper-inject-wedged" "$STATE/.afk-launch-backup.*" 2>/dev/null || reclaim_rc=$?
  if [ "$reclaim_rc" -eq 1 ]; then
    append_evidence lifecycle 'a leftover away-mode rollback backup could not be fully reclaimed; retry catch-up before ordinary work' "$evidence"
    lifecycle_ok=0
  fi

  if [ -s "$STATE/.subsuper-inject-wedged" ]; then
    wedge=$(head -1 "$STATE/.subsuper-inject-wedged" 2>/dev/null || true)
    append_evidence wedge "$wedge" "$evidence"
  fi
  if [ -s "$STATE/.subsuper-escalations" ]; then
    escalations=$(cat "$STATE/.subsuper-escalations" 2>/dev/null || true)
    append_evidence escalation "$escalations" "$evidence"
  fi
  # Whatever away_ledger_reclaim_backups could not adopt above (a live buffer/
  # sidecar/wedge conflicted with a backup's group) is folded here from each
  # backup's own preserved sidecar count, then removed - so a backup blocked
  # from adoption by a live conflict is never silently discarded and never
  # left to resurface as a duplicate once the live conflict eventually clears.
  retained=$(away_ledger_fold_retained_backups "$STATE" "$STATE/.subsuper-escalations" \
    "$STATE/.subsuper-inject-wedged" "$STATE/.afk-launch-backup.*" 2>/dev/null || true)
  if [ -n "$retained" ]; then
    append_evidence away-retained "$retained" "$evidence"
  fi
  # An accepted away batch has already been receipted and its buffer truncated, so
  # the ledger owner's private digests are the only local copy of those events.
  # Fold them in BEFORE anything retires them.
  away_items=$(away_ledger_fold_digests "$STATE" 2>/dev/null || true)
  if [ -n "$away_items" ]; then
    append_evidence away-telegram "$away_items" "$evidence"
  fi

  scan_open_blockers > "$blockers"
  if [ "$lifecycle_ok" -ne 1 ] || [ -s "$blockers" ]; then
    write_gate "$evidence" "$blockers" || { rm -f "$evidence" "$blockers"; return 1; }
    printf 'fm-afk-return: catch-up must finish before the captain request\n' >&2
    print_evidence "$GATE" >&2
    print_blockers "$GATE" >&2
    printf 'fm-afk-return: handle each blocker now, or close it with resolved [key=...] and append a durable reclassification reason, then run bin/fm-afk-return.sh check\n' >&2
    rm -f "$evidence" "$blockers"
    return 3
  fi

  print_evidence "$evidence"
  rm -f "$GATE"
  clear_delivery_artifacts
  rm -f "$evidence" "$blockers"
  printf 'fm-afk-return: catch-up clear; ordinary captain work may proceed\n'
  return 0
}

main() {
  local mode=${1:-begin} rc
  case "$mode" in
    begin|check) ;;
    guard) return_guard; return ;;
    -h|--help|help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac

  # The mutating begin/check paths need locks and the keyed status fold.
  # `guard` returned above without sourcing fm-wake-lib.sh, whose initialization
  # creates the state directory, so the advertised read-only guard is literal.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"

  mkdir -p "$STATE" || return 1
  fm_lock_acquire_wait "$LOCK"
  trap 'fm_lock_release "$LOCK"' EXIT
  write_pending_seed || { fm_lock_release "$LOCK"; trap - EXIT; return 1; }
  return_reconcile
  rc=$?
  fm_lock_release "$LOCK"
  trap - EXIT
  return "$rc"
}

main "$@"
