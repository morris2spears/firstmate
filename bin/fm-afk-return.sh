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
  # Retire the complete owned unit and every away batch version through the
  # ledger owner. This is the ACKNOWLEDGEMENT boundary: it only runs once the
  # catch-up evidence has folded in the live digests and every retained version
  # and no blocker is left, and it runs BEFORE the gate is removed - its status
  # decides whether the gate may close at all. A version that survived retirement
  # would otherwise be folded again by the next catch-up and presented as fresh
  # work, so a failure here keeps the gate open instead. The text-free
  # <id>.status delivery evidence is deliberately kept.
  local result=0
  away_ledger_retire_batch "$STATE" "$STATE/.subsuper-escalations" \
    "$STATE/.subsuper-inject-wedged" || result=1
  away_ledger_versions_retire_all "$STATE" || result=1
  [ "$result" -eq 0 ] \
    || printf 'fm-afk-return: some away batch records could not be retired after catch-up\n' >&2
  return "$result"
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
  local evidence blockers drained wedge escalations away_items lifecycle_ok=1
  local fold_retained_rc=0
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

  # Every catch-up read below appends into the SAME evidence kind whether the text
  # came from the live unit or from a retained immutable batch version, because a
  # retained version's content is a prefix-subset of the live unit whenever the
  # live unit was materialised from it. append_evidence dedupes exact records per
  # kind, so each logical escalation reaches Firstmate exactly once instead of
  # once per source under two different labels.
  wedge=$(
    if [ -s "$STATE/.subsuper-inject-wedged" ]; then
      head -1 "$STATE/.subsuper-inject-wedged" 2>/dev/null || true
    fi
    away_ledger_fold_versions "$STATE" wedges 2>/dev/null || true
  )
  append_evidence wedge "$wedge" "$evidence"
  # Only the lines the ledger has NOT already accounted for in a private away
  # digest: anything at or below `accounted` is reported once below as
  # away-telegram, and appending the whole buffer here would present the same
  # escalation to Firstmate as two separate catch-up items to act on. An absent
  # or unreadable record falls back to the whole buffer, so an unusable ledger
  # over-reports rather than dropping a captain-relevant line.
  #
  # The retained side is every immutable away batch version still in the store:
  # one whose active-pointer switch was refused (a daemon still live, e.g. after
  # a failed stop), one whose launch transaction was abandoned, and the one a
  # fresh away entry published before retiring that content from the live paths.
  # All of it is read-only here; nothing is retired before the acknowledgement in
  # clear_delivery_artifacts.
  escalations=$(
    away_ledger_unaccounted_lines "$STATE/.subsuper-escalations" 2>/dev/null || true
    away_ledger_fold_versions "$STATE" escalations 2>/dev/null || exit 1
  ) || fold_retained_rc=$?
  append_evidence escalation "$escalations" "$evidence"
  # An accepted away batch has already been receipted and its buffer truncated, so
  # the ledger owner's private digests are the only local copy of those events.
  # Fold them in BEFORE anything retires them.
  away_items=$(
    away_ledger_fold_digests "$STATE" 2>/dev/null || true
    away_ledger_fold_versions "$STATE" digests 2>/dev/null || exit 1
  ) || fold_retained_rc=$?
  append_evidence away-telegram "$away_items" "$evidence"
  if [ "$fold_retained_rc" -ne 0 ]; then
    append_evidence lifecycle 'a retained away-mode batch version could not be read; retry catch-up before ordinary work' "$evidence"
    lifecycle_ok=0
  fi

  scan_open_blockers > "$blockers"
  # Retirement is part of acknowledgement, so it is attempted BEFORE the gate can
  # close and a failure gates the catch-up exactly like an unresolved blocker.
  # Re-running is safe and does not duplicate: the gate preserves this evidence
  # and append_evidence dedupes exact records, so the next pass folds the same
  # surviving version into the same records it already published.
  if [ "$lifecycle_ok" -eq 1 ] && [ ! -s "$blockers" ] && ! clear_delivery_artifacts; then
    append_evidence lifecycle 'away batch records could not be retired; retry catch-up before ordinary work' "$evidence"
    lifecycle_ok=0
  fi
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
