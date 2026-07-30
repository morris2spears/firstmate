# shellcheck shell=bash
# The single owner of the away-mode escalation batch ledger.
#
# One away batch is the buffer state/.subsuper-escalations plus ONE ledger record
# in its state/.subsuper-escalations.since sidecar:
#
#   <arrival-epoch>-<nonce> <reserved> <confirmed> <accounted> <attempt> <retry-after> <last-delivery-id>
#
#   arrival-epoch  keeps the batch-age semantics the daemon's batching needs.
#   nonce          makes the identity minted-once, so no later batch can ever
#                  inherit a retired batch's counts.
#   reserved       leading buffer lines that must NEVER be sent to the phone
#                  again. Claimed BEFORE the network call, so a crash mid-send
#                  cannot become a duplicate captain alert. A reservation is given
#                  back ONLY when the send provably never left the box.
#   confirmed      leading lines Telegram provably accepted, proven by the durable
#                  delivery evidence - never inferred from a reservation, and only
#                  ever advanced over a CONTIGUOUS prefix (away_ledger_confirm
#                  refuses to jump an unconfirmed gap), so an accepted suffix can
#                  never imply acceptance of an earlier uncertain line.
#   accounted      leading lines whose text is captured in a private away digest.
#                  Anything past this count still has to reach captain chat.
#   attempt        the batch's delivery-attempt ordinal, folded into every delivery
#                  id. It advances ONLY when a proven-local failure retires an
#                  attempt, which is what lets the same lines be offered to the
#                  phone again under a fresh id while the retired attempt's
#                  evidence stays durable and auditable. An ambiguous outcome
#                  never advances it, so it can never be retried.
#   retry-after    the epoch before which this batch may not be offered to the
#                  phone again. Set when a proven-local failure retires an attempt,
#                  so a persistent local failure retries on a bounded schedule
#                  instead of once per housekeeping tick; cleared by acceptance.
#   delivery-id    the most recent delivery this batch attempted.
#
# Earlier record shapes - the bare arrival epoch of the pre-ledger form, and the
# five- and six-field forms that predate the attempt ordinal and the retry
# schedule - are migrated in place on read, so an in-place daemon upgrade during a
# live away session keeps its counts instead of failing closed and repeating
# already-delivered lines in captain chat.
#
# The invariant accounted <= confirmed <= reserved holds at every transition, and
# an unparseable record is reported as `unknown`, which callers must treat as
# fail-closed: nothing to the phone, everything to the visible in-session
# escalation. Callers never keep their own counters and never retire a digest or
# a ledger record themselves - they query and transition this owner, so the away
# daemon, away start, and away return all agree on one state machine.
#
# All of it lives in the sidecar because every away lifecycle path already
# retires, backs up, and restores that sidecar together with its buffer through
# this owner's away_ledger_snapshot/away_ledger_restore/away_ledger_retire_batch,
# never by enumerating the artifact set itself. away launch's crash rollback
# copies the whole unit (buffer, sidecar, wedge marker, digest directory) as
# opaque bytes rather than reading or advancing counts, so it cannot
# desynchronise the state machine, and away-mode's own flag file is the one
# artifact outside this unit - it belongs to the launcher, not the ledger.

FM_AWAY_LEDGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-x-lib.sh
. "$FM_AWAY_LEDGER_DIR/fm-x-lib.sh"

away_ledger_now() { date +%s; }

# One shared numeric-count validator, so every entry point rejects a malformed or
# missing count on its own rather than concatenating several and hoping.
away_ledger_is_count() {  # <value>...
  local v
  for v in "$@"; do
    case "$v" in
      ''|*[!0-9]*) return 1 ;;
    esac
  done
  return 0
}

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
away_ledger_write() {  # <buf> <batch-id> <reserved> <confirmed> <accounted> <attempt> <retry-after> <delivery-id>
  local buf=$1 id=$2 reserved=$3 confirmed=$4 accounted=$5 attempt=$6 retry=$7 did=$8 file tmp
  away_ledger_is_count "$reserved" "$confirmed" "$accounted" "$attempt" "$retry" || return 1
  file="${buf}.since"
  tmp=$(umask 077; mktemp "${file}.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s %s %s %s %s %s %s\n' \
      "$id" "$reserved" "$confirmed" "$accounted" "$attempt" "$retry" "$did" \
      > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$file" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# Start the ledger for a brand new batch: a fresh identity and nothing delivered.
away_ledger_open() {  # <buf>
  away_ledger_write "$1" "$(away_ledger_mint_id)" 0 0 0 0 0 none
}

# Print "<batch-id> <reserved> <confirmed> <accounted> <attempt> <retry-after>
# <delivery-id>", or the single word `unknown` when the record is absent,
# malformed, or violates the accounted <= confirmed <= reserved invariant. Every
# earlier record shape is migrated in place rather than rejected:
#   1 field   the pre-ledger bare arrival epoch  -> minted identity, zero counts
#   5 fields  id reserved confirmed accounted did -> attempt 0, retry-after 0
#   6 fields  ... attempt did                     -> retry-after 0
away_ledger_read() {  # <buf>
  local buf=$1 raw f1 f2 f3 f4 f5 f6 f7 extra
  local id reserved confirmed accounted attempt retry did epoch nonce migrated=0
  raw=$(head -n 1 "${buf}.since" 2>/dev/null || true)
  IFS=' ' read -r f1 f2 f3 f4 f5 f6 f7 extra <<< "$raw"
  if [ -z "${f1:-}" ] || [ -n "${extra:-}" ]; then printf 'unknown\n'; return 0; fi
  id=$f1; reserved=${f2:-}; confirmed=${f3:-}; accounted=${f4:-}
  if [ -z "${f2:-}" ]; then
    reserved=0; confirmed=0; accounted=0; attempt=0; retry=0; did=none; migrated=1
  elif [ -z "${f3:-}" ] || [ -z "${f4:-}" ] || [ -z "${f5:-}" ]; then
    printf 'unknown\n'; return 0
  elif [ -z "${f6:-}" ]; then
    attempt=0; retry=0; did=$f5; migrated=1
  elif [ -z "${f7:-}" ]; then
    attempt=$f5; retry=0; did=$f6; migrated=1
  else
    attempt=$f5; retry=$f6; did=$f7
  fi
  epoch=${id%%-*}
  nonce=${id#*-}
  away_ledger_is_count "$epoch" "$reserved" "$confirmed" "$accounted" "$attempt" "$retry" \
    || { printf 'unknown\n'; return 0; }
  case "$did" in ''|*[!0-9a-zA-Z-]*) printf 'unknown\n'; return 0 ;; esac
  if [ "$accounted" -gt "$confirmed" ] || [ "$confirmed" -gt "$reserved" ]; then
    printf 'unknown\n'; return 0
  fi
  if [ -z "$nonce" ] || [ "$nonce" = "$id" ]; then
    id="$epoch-$(away_ledger_hash "$$-${RANDOM:-0}-$epoch")"
    migrated=1
  fi
  if [ "$migrated" -eq 1 ]; then
    away_ledger_write "$buf" "$id" "$reserved" "$confirmed" "$accounted" "$attempt" "$retry" "$did" \
      || { printf 'unknown\n'; return 0; }
  fi
  printf '%s %s %s %s %s %s %s\n' \
    "$id" "$reserved" "$confirmed" "$accounted" "$attempt" "$retry" "$did"
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
  local buf=$1 field=$2 value=$3 did=${4:-}
  local rec id reserved confirmed accounted attempt retry current
  away_ledger_is_count "$value" || return 1
  rec=$(away_ledger_read "$buf")
  [ "$rec" != unknown ] || return 1
  IFS=' ' read -r id reserved confirmed accounted attempt retry current <<< "$rec"
  [ -n "$did" ] || did=$current
  case "$field" in
    reserved) reserved=$value ;;
    confirmed) confirmed=$value; retry=0 ;;
    accounted) accounted=$value ;;
    *) return 1 ;;
  esac
  [ "$confirmed" -le "$reserved" ] || confirmed=$reserved
  [ "$accounted" -le "$confirmed" ] || accounted=$confirmed
  away_ledger_write "$buf" "$id" "$reserved" "$confirmed" "$accounted" "$attempt" "$retry" "$did"
}

# Whether the batch may be offered to the phone right now: false while a retired
# proven-local attempt's retry schedule has not yet elapsed.
away_ledger_retry_due() {  # <retry-after>
  local retry=${1:-0}
  away_ledger_is_count "$retry" || return 1
  [ "$retry" -eq 0 ] && return 0
  [ "$(away_ledger_now)" -ge "$retry" ]
}

# Claim lines for the phone BEFORE the network call.
away_ledger_reserve() {  # <buf> <reserved> <delivery-id>
  away_ledger_transition "$1" reserved "$2" "$3"
}

# Retire an attempt that PROVABLY never left the box: give its claim back, advance
# the attempt ordinal, and arm the retry schedule, all in the same atomic write, so
# the very same lines can be offered to the phone again under a fresh delivery id
# once <retry-delay-secs> has elapsed, while the retired attempt's evidence record
# stays durable and auditable. This is the only transition that advances the
# ordinal, so an ambiguous outcome - which keeps its claim - can never be retried,
# and the schedule keeps a persistent local failure from re-attempting (and minting
# a fresh evidence record) on every housekeeping tick.
away_ledger_release() {  # <buf> <reserved> <delivery-id> [retry-delay-secs]
  local buf=$1 reserved=$2 did=$3 delay=${4:-0}
  local rec id r c a attempt retry current
  away_ledger_is_count "$reserved" || return 1
  away_ledger_is_count "$delay" || delay=0
  rec=$(away_ledger_read "$buf")
  [ "$rec" != unknown ] || return 1
  IFS=' ' read -r id r c a attempt retry current <<< "$rec"
  [ -n "$did" ] || did=$current
  [ "$reserved" -ge "$c" ] || reserved=$c
  retry=0
  [ "$delay" -le 0 ] || retry=$(( $(away_ledger_now) + delay ))
  away_ledger_write "$buf" "$id" "$reserved" "$c" "$a" "$((attempt + 1))" "$retry" "$did"
}

# Record evidence-proven Telegram acceptance for the range (<from>, <to>].
# Refuses unless <from> is exactly the current confirmed count, so confirmation can
# only ever extend a contiguous proven prefix. `reserved > confirmed` therefore
# means an unresolved send, and the caller must not offer this batch to the phone
# again until that reservation is resolved.
away_ledger_confirm() {  # <buf> <from> <to> <delivery-id>
  local buf=$1 from=$2 to=$3 did=$4 rec id reserved confirmed accounted attempt retry current
  away_ledger_is_count "$from" "$to" || return 1
  rec=$(away_ledger_read "$buf")
  [ "$rec" != unknown ] || return 1
  IFS=' ' read -r id reserved confirmed accounted attempt retry current <<< "$rec"
  [ "$from" -eq "$confirmed" ] || return 1
  [ "$to" -ge "$confirmed" ] || return 1
  away_ledger_transition "$buf" confirmed "$to" "$did"
}

# The delivery identity of one send: batch, attempt ordinal, first line sent, and
# the exact body. Built here so no caller mints an away-delivery id of its own, and
# so a retired proven-local attempt gets a genuinely new id instead of colliding
# with its own tombstoned evidence.
away_ledger_delivery_id() {  # <batch-id> <attempt> <offset> <body>
  away_ledger_is_count "$2" "$3" || return 1
  printf '%s-a%s-%s-%s\n' "$1" "$2" "$3" "$(away_ledger_hash "$4")"
}

# Capture the batch lines in (<from>, <to>] into this delivery's private digest
# and account for them. <from> is the ACCOUNTED position rather than the send
# offset, so a delivery whose digest failed earlier is picked up by the next digest
# that succeeds; <to> is the CONFIRMED count, so an unproven line is never recorded
# as delivered.
away_ledger_digest_record() {  # <state> <buf> <delivery-id> <from> <to>
  local state=$1 buf=$2 did=$3 from=$4 to=$5 lines
  away_ledger_is_count "$from" "$to" || return 1
  [ -s "$buf" ] || return 0
  lines=$(( $(wc -l < "$buf" 2>/dev/null || echo 0) ))
  [ "$to" -le "$lines" ] || return 1
  [ "$to" -gt "$from" ] || return 0
  sed -n "$((from + 1)),${to}p" "$buf" 2>/dev/null \
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
  local state=$1 dir
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
#
# <preserve-digests>, when 1, keeps the digest directory intact. Callers pass 1
# when this call is reached on a continuation of an already-active away session
# (state/.afk was already present) rather than a genuinely fresh entry, so a
# crashed-daemon restart or a failed re-entry can never destroy digested items
# that Firstmate has not consumed or folded yet.
away_ledger_retire_working_records() {  # <state> [preserve-digests]
  local state=$1 preserve=${2:-0}
  [ "$preserve" -eq 1 ] || rm -rf "$(away_ledger_digest_dir "$state")" 2>/dev/null
  rm -f "$(away_ledger_delivery_dir "$state")"/.spool.* \
        "$state"/.subsuper-escalations.since.* 2>/dev/null
  return 0
}

# The complete owned artifact unit for one away batch transaction: the
# escalation buffer, its ledger sidecar, the wedge marker, and the private
# digest directory - every artifact a crash or a failed re-entry must resume
# exactly once from. The text-free <id>.status delivery evidence is NEVER part
# of this unit: it outlives every snapshot/restore/retire of the batch above it,
# so accepted/failed/unavailable outcomes stay auditable regardless of how many
# batches come and go over it.
#
# The away-mode lifecycle callers (launch, start, return) snapshot/restore/
# retire through these functions only; they never enumerate or independently
# delete an owned artifact themselves, so a rollback always restores the
# complete prior unit or leaves a durable recoverable transaction - never a
# partial mix of retired and restored pieces. The daemon's in-session success
# path does not call away_ledger_retire_batch: it only truncates the buffer and
# retires the sidecar/wedge marker, deliberately leaving the digest directory
# alone, because the away session is still live and its digests may still be
# needed by a later crash-recovery read or the eventual return fold.

# Copy the complete owned unit into <backup> (a directory the caller owns and
# is responsible for removing once it is no longer needed).
away_ledger_snapshot() {  # <state> <buf> <wedge> <backup>
  local state=$1 buf=$2 wedge=$3 backup=$4 artifact base digest_dir result=0
  mkdir -p "$backup" || return 1
  for artifact in "$buf" "${buf}.since" "$wedge"; do
    base=${artifact##*/}
    if [ -e "$artifact" ]; then
      cp -p "$artifact" "$backup/$base" || result=1
    fi
  done
  digest_dir=$(away_ledger_digest_dir "$state")
  if [ -d "$digest_dir" ]; then
    cp -pR "$digest_dir" "$backup/tg-away-digest" || result=1
  fi
  return "$result"
}

# Replace the complete owned unit with what <backup> holds (dropping whatever
# is currently on disk first), so a caller never ends up with some artifacts
# restored and others left from the failed attempt.
away_ledger_restore() {  # <state> <buf> <wedge> <backup>
  local state=$1 buf=$2 wedge=$3 backup=$4 artifact base digest_dir result=0
  rm -f "$buf" "${buf}.since" "$wedge" || result=1
  digest_dir=$(away_ledger_digest_dir "$state")
  rm -rf "$digest_dir" || result=1
  for artifact in "$buf" "${buf}.since" "$wedge"; do
    base=${artifact##*/}
    if [ -e "$backup/$base" ]; then
      cp -p "$backup/$base" "$artifact" || result=1
    fi
  done
  if [ -d "$backup/tg-away-digest" ]; then
    cp -pR "$backup/tg-away-digest" "$digest_dir" || result=1
  fi
  return "$result"
}

# Retire the complete owned unit for a lifecycle boundary (a fresh away entry,
# a mid-session restart, or a completed return catch-up): the escalation
# buffer, the wedge marker, the ledger sidecar, and this session's working
# records.
#
# <preserve-digests>, when 1, keeps the digest directory intact (see
# away_ledger_retire_working_records) - callers pass 1 on a continuation of an
# already-active away session rather than a genuinely fresh entry.
away_ledger_retire_batch() {  # <state> <buf> <wedge> [preserve-digests]
  local state=$1 buf=$2 wedge=$3 preserve=${4:-0} result=0
  rm -f "$buf" "$wedge" 2>/dev/null || result=1
  away_ledger_retire "$buf" || result=1
  away_ledger_retire_working_records "$state" "$preserve" || result=1
  return "$result"
}

# Reclaim every leftover rollback-backup directory matching <backup-glob>: a
# backup only survives past its own transaction when away_ledger_restore
# reported a failure and the caller (fm-afk-launch.sh) deliberately kept it
# rather than risk a partial restore. Two kinds of artifact inside it are
# treated differently:
#
#   digest text        merged into the live digest directory by delivery id,
#                       never overwriting an existing file there - a live
#                       <delivery-id>.items is always the same content, since
#                       delivery ids are unique per attempt, so this is always
#                       safe regardless of what else is live.
#
#   buffer + sidecar +  treated as ONE opaque unit, never gap-filled
#   wedge marker        artifact-by-artifact: the sidecar's reserved/confirmed/
#                       accounted counts are offsets into that EXACT buffer, so
#                       pairing a live buffer with a foreign backup sidecar (or
#                       vice versa) would silently misattribute counts onto
#                       unrelated escalation lines. The unit is adopted whole
#                       only when the live buffer, sidecar, and wedge marker
#                       are ALL absent (nothing live to conflict with); if any
#                       one of them is already live, the whole unit is left
#                       untouched inside the backup rather than partially
#                       merged or discarded, so a live session's lines are
#                       never shadowed and a backup's undigested lines are
#                       never silently lost - the backup simply waits for a
#                       later reclaim once the live unit clears (e.g. after
#                       the away session that owns it ends).
#
# The backup is removed only once every artifact it holds has been reconciled
# onto the live unit (digest merge) or adopted as a whole (buffer/sidecar/
# wedge) or was already redundant with what is live; a real copy/prepare/
# removal failure anywhere leaves the complete backup in place rather than
# discarding a copy that was never actually merged. Called before a new
# transaction begins (an already-running daemon's refresh) or after a launch
# transaction fully resolves (success or rollback), and at return, so no copy
# of actionable escalation text can outlive recovery, and never while a
# transaction is open, so a rollback can never erase what reclaim merged in.
#
# Return status distinguishes an ordinary wait state from a real fault:
#   0  every backup was fully reconciled (or none matched the glob)
#   2  deferred only - a live buffer/sidecar/wedge conflicts with at least one
#      backup's group, so that backup was correctly left untouched; this is
#      the normal state during an active away session and is not a failure
#   1  a real copy, directory-prepare, or removal failure occurred; callers
#      should surface this one, unlike the merely-deferred status above
away_ledger_reclaim_backups() {  # <state> <buf> <wedge> <backup-glob>
  local state=$1 buf=$2 wedge=$3 pattern=$4
  local backup digest_dir artifact base f ok real_fail group_clear_to_adopt group_ok
  local result=0 deferred=0
  digest_dir=$(away_ledger_digest_dir "$state")
  for backup in $pattern; do
    [ -d "$backup" ] || continue
    ok=1
    real_fail=0
    if [ -d "$backup/tg-away-digest" ]; then
      if fmx_private_artifact_dir_prepare "$digest_dir" >/dev/null 2>&1; then
        for f in "$backup/tg-away-digest"/*.items; do
          [ -f "$f" ] || continue
          base=${f##*/}
          if [ -e "$digest_dir/$base" ]; then
            :
          elif ! cp -p "$f" "$digest_dir/$base"; then
            ok=0; real_fail=1
          fi
        done
      else
        ok=0; real_fail=1
      fi
    fi
    if [ -e "$backup/${buf##*/}" ] || [ -e "$backup/${buf##*/}.since" ] \
      || [ -e "$backup/${wedge##*/}" ]; then
      group_clear_to_adopt=0
      [ -e "$buf" ] || [ -e "${buf}.since" ] || [ -e "$wedge" ] || group_clear_to_adopt=1
      if [ "$group_clear_to_adopt" -eq 1 ]; then
        group_ok=1
        for artifact in "$buf" "${buf}.since" "$wedge"; do
          base=${artifact##*/}
          [ -e "$backup/$base" ] || continue
          cp -p "$backup/$base" "$artifact" || { group_ok=0; ok=0; real_fail=1; }
        done
        # Consume the group from the backup as soon as it is fully adopted,
        # independent of any unrelated digest-merge outcome above, so a
        # digest failure alone can never leave an already-adopted group
        # sitting in the backup to be folded a second time by
        # away_ledger_fold_retained_backups.
        if [ "$group_ok" -eq 1 ]; then
          rm -f "$backup/${buf##*/}" "$backup/${buf##*/}.since" "$backup/${wedge##*/}" \
            || { ok=0; real_fail=1; }
        fi
      else
        ok=0
        deferred=1
      fi
    fi
    if [ "$ok" -eq 1 ]; then
      rm -rf "$backup" || { result=1; real_fail=1; }
    elif [ "$real_fail" -eq 1 ]; then
      result=1
    fi
  done
  [ "$result" -eq 0 ] || return 1
  [ "$deferred" -eq 0 ] || return 2
  return 0
}

# Fold the actionable content of every backup that away_ledger_reclaim_backups
# left behind (deferred: its buffer/sidecar/wedge group conflicted with a live
# one) directly into the caller's evidence, then remove it - so a backup
# blocked from adoption by a live conflict is never silently discarded, and
# never left to resurface as a duplicate delivery once the live conflict
# eventually clears. Digest text needs no separate handling here: it is always
# merged by away_ledger_reclaim_backups regardless of any buffer conflict, so
# by the time this runs a remaining backup's digest text is already reconciled
# and only its raw buffer/wedge content can still be stranded.
#
# Reads each backup's own escalation count through its own preserved sidecar
# (away_ledger_read against the backup's own buffer path), so only the lines
# past that backup's own accounted count - never anything already digested -
# are printed, one whitespace-joined line per backup, tagged so the caller can
# label it distinctly from the live buffer's own evidence.
away_ledger_fold_retained_backups() {  # <state> <buf> <wedge> <backup-glob>
  local state=$1 buf=$2 wedge=$3 pattern=$4
  local backup bbuf accounted rec n body wedge_body result=0
  for backup in $pattern; do
    [ -d "$backup" ] || continue
    bbuf="$backup/${buf##*/}"
    accounted=0
    if [ -f "$bbuf" ] && [ -f "${bbuf}.since" ]; then
      rec=$(away_ledger_read "$bbuf")
      if [ "$rec" != unknown ]; then
        IFS=' ' read -r _ _ _ accounted _ _ _ <<< "$rec"
      fi
    fi
    if [ -f "$bbuf" ]; then
      n=$(( $(wc -l < "$bbuf" 2>/dev/null || echo 0) ))
      if [ "$n" -gt "$accounted" ]; then
        body=$(tail -n "+$((accounted + 1))" "$bbuf" 2>/dev/null \
          | awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}')
        printf '%s\n' "$body"
      fi
    fi
    if [ -s "$backup/${wedge##*/}" ]; then
      wedge_body=$(head -1 "$backup/${wedge##*/}" 2>/dev/null)
      printf 'wedge: %s\n' "$wedge_body"
    fi
    rm -rf "$backup" || result=1
  done
  return "$result"
}
