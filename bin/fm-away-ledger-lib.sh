# shellcheck shell=bash
# The single owner of the away-mode escalation batch ledger.
#
# One away batch is the buffer state/.subsuper-escalations plus ONE ledger record
# in its state/.subsuper-escalations.since sidecar:
#
#   <arrival-epoch>-<nonce> <reserved> <confirmed> <accounted> <last-delivery-id>
#
#   arrival-epoch  keeps the batch-age semantics the daemon's batching needs.
#   nonce          makes the identity minted-once, so no later batch can ever
#                  inherit a retired batch's counts.
#   reserved       leading buffer lines that must NEVER be sent to the phone
#                  again. Claimed BEFORE the network call, so a crash mid-send
#                  cannot become a duplicate captain alert.
#   confirmed      leading lines Telegram provably accepted, proven by the
#                  durable delivery evidence - never inferred from a reservation.
#   accounted      leading lines whose text is captured in a private away digest.
#                  Anything past this count still has to reach captain chat.
#   delivery-id    the most recent delivery this batch attempted.
#
# The invariant accounted <= confirmed <= reserved holds at every transition, and
# an unparseable record is reported as `unknown`, which callers must treat as
# fail-closed: nothing to the phone, everything to the visible in-session
# escalation. Callers never keep their own counters and never delete a digest or
# a ledger themselves - they query and transition this owner, so the away daemon,
# away start, and away return all agree on one state machine.
#
# All of it lives in the sidecar because every away lifecycle path already
# retires, backs up, and restores that sidecar together with its buffer.

FM_AWAY_LEDGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-x-lib.sh
. "$FM_AWAY_LEDGER_DIR/fm-x-lib.sh"

away_ledger_now() { date +%s; }

away_ledger_hash() {
  local h
  if command -v md5 >/dev/null 2>&1; then h=$(printf '%s' "$1" | md5 -q)
  else h=$(printf '%s' "$1" | md5sum | cut -d ' ' -f1); fi
  printf '%s\n' "${h:0:16}"
}

away_ledger_digest_dir() {  # <state>
  printf '%s\n' "$1/tg-away-digest"
}

away_ledger_delivery_dir() {  # <state>
  printf '%s\n' "$1/tg-away-delivery"
}

away_ledger_mint_id() {
  local now
  now=$(away_ledger_now)
  printf '%s-%s\n' "$now" "$(away_ledger_hash "$$-${RANDOM:-0}-${RANDOM:-0}-$now")"
}

# Atomically replace the whole record. Same-directory mktemp plus mv, so a reader
# never sees a half-written ledger.
away_ledger_write() {  # <buf> <batch-id> <reserved> <confirmed> <accounted> <delivery-id>
  local buf=$1 id=$2 reserved=$3 confirmed=$4 accounted=$5 did=$6 file tmp
  file="${buf}.since"
  tmp=$(umask 077; mktemp "${file}.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s %s %s %s %s\n' "$id" "$reserved" "$confirmed" "$accounted" "$did" \
      > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$file" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# Start the ledger for a brand new batch: a fresh identity and nothing delivered.
away_ledger_open() {  # <buf>
  away_ledger_write "$1" "$(away_ledger_mint_id)" 0 0 0 none
}

# Print "<batch-id> <reserved> <confirmed> <accounted> <delivery-id>", or the
# single word `unknown` when the record is absent, malformed, or violates the
# accounted <= confirmed <= reserved invariant. A bare epoch (the pre-ledger
# form) is upgraded in place to a minted identity with zero counts, which is
# exactly "nothing delivered yet".
away_ledger_read() {  # <buf>
  local buf=$1 raw id reserved confirmed accounted did extra epoch nonce
  raw=$(head -n 1 "${buf}.since" 2>/dev/null || true)
  IFS=' ' read -r id reserved confirmed accounted did extra <<< "$raw"
  if [ -z "${id:-}" ] || [ -n "${extra:-}" ]; then printf 'unknown\n'; return 0; fi
  if [ -z "${reserved:-}" ] && [ -z "${confirmed:-}" ] \
    && [ -z "${accounted:-}" ] && [ -z "${did:-}" ]; then
    reserved=0; confirmed=0; accounted=0; did=none
  elif [ -z "${reserved:-}" ] || [ -z "${confirmed:-}" ] \
    || [ -z "${accounted:-}" ] || [ -z "${did:-}" ]; then
    printf 'unknown\n'; return 0
  fi
  epoch=${id%%-*}
  nonce=${id#*-}
  case "$epoch" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  case "$reserved$confirmed$accounted" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
  case "$did" in ''|*[!0-9a-zA-Z-]*) printf 'unknown\n'; return 0 ;; esac
  if [ "$accounted" -gt "$confirmed" ] || [ "$confirmed" -gt "$reserved" ]; then
    printf 'unknown\n'; return 0
  fi
  if [ -z "$nonce" ] || [ "$nonce" = "$id" ]; then
    id="$epoch-$(away_ledger_hash "$$-${RANDOM:-0}-$epoch")"
    away_ledger_write "$buf" "$id" "$reserved" "$confirmed" "$accounted" "$did" \
      || { printf 'unknown\n'; return 0; }
  fi
  printf '%s %s %s %s %s\n' "$id" "$reserved" "$confirmed" "$accounted" "$did"
}

# The batch's arrival epoch, for age-based batching. Non-zero when there is no
# usable record.
away_ledger_epoch() {  # <buf>
  local raw epoch
  raw=$(head -n 1 "${1}.since" 2>/dev/null || true)
  epoch=${raw%% *}
  epoch=${epoch%%-*}
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$epoch"
  return 0
}

# The only mutation path for the three counts. Reads the current record, applies
# ONE named transition, re-establishes the invariant, and writes it back, so no
# caller can leave the ledger internally inconsistent.
away_ledger_transition() {  # <buf> reserved|confirmed|accounted <value> [delivery-id]
  local buf=$1 field=$2 value=$3 did=${4:-} rec id reserved confirmed accounted current
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  rec=$(away_ledger_read "$buf")
  [ "$rec" != unknown ] || return 1
  IFS=' ' read -r id reserved confirmed accounted current <<< "$rec"
  [ -n "$did" ] || did=$current
  case "$field" in
    reserved) reserved=$value ;;
    confirmed) confirmed=$value ;;
    accounted) accounted=$value ;;
    *) return 1 ;;
  esac
  [ "$confirmed" -le "$reserved" ] || confirmed=$reserved
  [ "$accounted" -le "$confirmed" ] || accounted=$confirmed
  away_ledger_write "$buf" "$id" "$reserved" "$confirmed" "$accounted" "$did"
}

# Claim lines for the phone BEFORE the network call.
away_ledger_reserve() {  # <buf> <reserved> <delivery-id>
  away_ledger_transition "$1" reserved "$2" "$3"
}

# Give a claim back after a send that provably never left the box.
away_ledger_release() {  # <buf> <reserved> <delivery-id>
  away_ledger_transition "$1" reserved "$2" "$3"
}

# Record evidence-proven Telegram acceptance.
away_ledger_confirm() {  # <buf> <confirmed> <delivery-id>
  away_ledger_transition "$1" confirmed "$2" "$3"
}

# Capture lines past <from> into this delivery's private digest and account for
# them. Writing from the ACCOUNTED position rather than the send offset means a
# delivery whose digest failed earlier is picked up by the next digest that
# succeeds, so no accepted line is ever left out of both records.
away_ledger_digest_record() {  # <state> <buf> <delivery-id> <from>
  local state=$1 buf=$2 did=$3 from=$4 to
  case "$from" in ''|*[!0-9]*) return 1 ;; esac
  [ -s "$buf" ] || return 0
  to=$(( $(wc -l < "$buf" 2>/dev/null || echo 0) ))
  [ "$to" -gt "$from" ] || return 0
  tail -n "+$((from + 1))" "$buf" 2>/dev/null \
    | fmx_private_artifact_publish_stdin "$(away_ledger_digest_dir "$state")" "$did.items" 600 \
      2>/dev/null || return 1
  away_ledger_transition "$buf" accounted "$to" "$did"
}

# Every delivery of a batch shares the batch id prefix, so ONE pointer covers all
# of a grown batch's digests - the receipt never names a single delivery's file.
away_ledger_digest_pointer() {  # <batch-id>
  printf 'state/tg-away-digest/%s-*.items\n' "$1"
}

# Print every recorded away item so the return catch-up can fold them into its
# evidence BEFORE anything retires them.
away_ledger_fold_digests() {  # <state>
  local state=$1 dir f
  dir=$(away_ledger_digest_dir "$state")
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.items; do
    [ -f "$f" ] || continue
    cat "$f" 2>/dev/null || true
  done
  return 0
}

# Private 0700-directory spool for one outbound alert, so the text never lands
# outside the firstmate home even if the daemon is killed mid-send.
away_ledger_spool_create() {  # <state>
  local dir
  dir=$(away_ledger_delivery_dir "$state")
  fmx_private_artifact_dir_prepare "$dir" >/dev/null 2>&1 || return 1
  (umask 077; mktemp "$dir/.spool.XXXXXX" 2>/dev/null) || return 1
}

# Retire the ledger of a batch that has been fully delivered in session.
away_ledger_retire() {  # <buf>
  rm -f "${1}.since" "${1}".since.* 2>/dev/null
  return 0
}

# Retire the away session's working records: the private digests, any leaked
# spool, and any ledger temp. The text-free <id>.status delivery evidence is
# deliberately kept, so accepted/failed/unavailable outcomes stay auditable.
away_ledger_retire_working_records() {  # <state>
  local state=$1
  rm -rf "$(away_ledger_digest_dir "$state")" 2>/dev/null
  rm -f "$(away_ledger_delivery_dir "$state")"/.spool.* \
        "$state"/.subsuper-escalations.since.* 2>/dev/null
  return 0
}
