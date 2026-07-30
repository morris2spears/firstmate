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
# schedule - are normalised by away_ledger_parse and migrated in place by the LIVE
# read (away_ledger_read), so an in-place daemon upgrade during a live away
# session keeps its counts instead of failing closed and repeating
# already-delivered lines in captain chat. A read of a published immutable version
# goes through away_ledger_peek instead, which never writes; that migration
# happens only while a successor version is being constructed.
#
# The invariant accounted <= confirmed <= reserved holds at every transition, and
# an unparseable record is reported as `unknown`, which callers must treat as
# fail-closed: nothing to the phone, everything to the visible in-session
# escalation. Callers never keep their own counters and never retire a digest or
# a ledger record themselves - they query and transition this owner, so the away
# daemon, away start, and away return all agree on one state machine.
#
# All of it lives in the sidecar because every away lifecycle path already
# retires, publishes, and restores that sidecar together with its buffer through
# this owner's immutable version store (away_ledger_version_publish /
# away_ledger_version_activate / away_ledger_retire_batch), never by enumerating
# the artifact set itself. away launch's crash rollback publishes the whole unit
# (buffer, sidecar, wedge marker, digest directory) as one opaque immutable
# version rather than reading or advancing counts, so it cannot desynchronise the
# state machine, and away-mode's own flag file is the one artifact outside this
# unit - it belongs to the launcher, not the ledger.

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

# A minted-once identity. The entropy comes from a mktemp token rather than
# $RANDOM: this owner mints ids from inside command substitutions, and in bash 3.2
# $RANDOM restarts from the parent's state in every one of those, so two mints in
# the same second within one process produce the SAME value - which would give two
# batches one identity and two versions one directory name. mktemp's uniqueness
# does not depend on that sequence. <scope-dir>, when given, is where the token is
# created (it is removed immediately); the old scheme remains the fallback.
away_ledger_mint_id() {  # [scope-dir]
  local now token dir
  now=$(away_ledger_now)
  dir=${1:-${TMPDIR:-/tmp}}
  if token=$(umask 077; mktemp "$dir/.mint.XXXXXX" 2>/dev/null); then
    printf '%s-%s\n' "$now" "$(away_ledger_hash "$$-${token##*/}-${RANDOM:-0}-$now")"
    rm -f -- "$token" 2>/dev/null
    return 0
  fi
  printf '%s-%s\n' "$now" "$(away_ledger_hash "$$-${RANDOM:-0}-${RANDOM:-0}-$now")"
}

# Write one record next to <buf> with a same-directory mktemp plus mv, so a reader
# never sees a half-written ledger. PRIVATE: this is the raw file write used to
# build a successor version's own sidecar inside private staging. A LIVE record
# change goes through away_ledger_write, which commits a validated successor
# version and switches the active pointer before any live path changes.
_away_ledger_record_put() {  # <buf> <batch-id> <reserved> <confirmed> <accounted> <attempt> <retry-after> <delivery-id>
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

# The live away unit a buffer path belongs to. The unit is one fixed artifact set
# inside one state directory, so the transition path derives it from the buffer
# rather than making every caller thread three paths through; the lifecycle
# callers keep the explicit-path API.
away_ledger_state_of() {  # <buf>
  printf '%s\n' "${1%/*}"
}

away_ledger_wedge_of() {  # <state>
  printf '%s\n' "$1/.subsuper-inject-wedged"
}

# The in-session (captain chat) delivery state of the current batch, part of the
# owned unit like every other artifact: "<batch-id> <lines> attempting|confirmed".
# It exists so a bookkeeping failure AFTER a confirmed submit can never become a
# second delivery of the same batch into captain chat.
away_ledger_chat_of() {  # <state>
  printf '%s\n' "$1/.subsuper-chat-delivery"
}

# The unit's artifact slots, in one place, so a slot can never be copied by the
# staging build and then forgotten by the projection (or the reverse).
_away_ledger_unit_paths() {  # <state> <buf> <wedge>
  printf '%s\n%s\n%s\n%s\n' "$2" "${2}.since" "$3" "$(away_ledger_chat_of "$1")"
}

_away_ledger_unit_slots() {
  printf 'escalations\nescalations.since\nwedge\nchat\n'
}

# Every LIVE record change is a version transition: a complete successor version
# carrying the new record is built, validated, and published, and only then does
# the active pointer switch and the live projection get rewritten.
away_ledger_write() {  # <buf> <batch-id> <reserved> <confirmed> <accounted> <attempt> <retry-after> <delivery-id>
  local buf=$1 state
  away_ledger_is_count "$3" "$4" "$5" "$6" "$7" || return 1
  state=$(away_ledger_state_of "$buf")
  away_ledger_transact "$state" "$buf" "$(away_ledger_wedge_of "$state")" \
    _away_ledger_mut_record "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# Start the ledger for a brand new batch: a fresh identity and nothing delivered.
away_ledger_open() {  # <buf>
  away_ledger_write "$1" "$(away_ledger_mint_id "$(away_ledger_state_of "$1")")" 0 0 0 0 0 none
}

# Append one distilled escalation line to the batch. The daemon's own append is a
# version transition like every other, so the line is durable in a published
# version before it is visible in the live buffer.
away_ledger_append() {  # <buf> <line>
  local buf=$1 state
  state=$(away_ledger_state_of "$buf")
  away_ledger_transact "$state" "$buf" "$(away_ledger_wedge_of "$state")" \
    _away_ledger_mut_append "$2"
}

# Retire a fully in-session-delivered batch: the buffer is emptied and the record
# and wedge marker are dropped, all as ONE successor version, so no intermediate
# state where a truncated buffer is still paired with its old counts is ever
# published or projected.
away_ledger_truncate() {  # <buf>
  local buf=$1 state
  state=$(away_ledger_state_of "$buf")
  away_ledger_transact "$state" "$buf" "$(away_ledger_wedge_of "$state")" \
    _away_ledger_mut_truncate
}

# Record the wedge evidence for the unit, text on stdin only.
away_ledger_wedge_record() {  # <state>
  local state=$1 tmp rc
  tmp=$(umask 077; mktemp "$state/.subsuper-inject-wedged.stage.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
    return 1
  fi
  away_ledger_transact "$state" "$state/.subsuper-escalations" \
    "$(away_ledger_wedge_of "$state")" _away_ledger_mut_wedge "$tmp"
  rc=$?
  rm -f -- "$tmp" 2>/dev/null
  return "$rc"
}

away_ledger_wedge_clear() {  # <state>
  local state=$1
  [ -e "$(away_ledger_wedge_of "$state")" ] || return 0
  away_ledger_transact "$state" "$state/.subsuper-escalations" \
    "$(away_ledger_wedge_of "$state")" _away_ledger_mut_wedge_clear
}

# The transition mutators. Each edits ONLY the private staging copy of the unit it
# is handed; none may touch a live path, and the transaction below is what turns a
# mutated staging directory into a published version and then a live projection.
_away_ledger_mut_record() {  # <id> <r> <c> <a> <attempt> <retry> <did> <staging>
  local staging=$8
  [ -e "$staging/escalations" ] || : > "$staging/escalations" 2>/dev/null || return 1
  _away_ledger_record_put "$staging/escalations" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

_away_ledger_mut_append() {  # <line> <staging>
  printf '%s\n' "$1" >> "$2/escalations" 2>/dev/null
}

_away_ledger_mut_truncate() {  # <staging>
  : > "$1/escalations" 2>/dev/null || return 1
  rm -f -- "$1/escalations.since" "$1/wedge" "$1/chat" 2>/dev/null || return 1
  return 0
}

_away_ledger_mut_chat() {  # <batch-id> <confirmed> <attempt-from> <attempt-to> <staging>
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$5/chat" 2>/dev/null
}

# The in-session delivery receipt, parsed as INDEPENDENT fields:
#
#   <batch-id> <confirmed> <attempt-from> <attempt-to>
#
# `confirmed` is the monotonic prefix of the batch captain chat PROVABLY has, and
# the attempt range is the suffix a submit is currently offering it. They are
# separate on purpose: starting an attempt must never lower the confirmed prefix,
# so an inject that fails (or a crash between the attempt record and the submit)
# cannot drag already-delivered lines back into captain chat.
#
# The legacy 3-field "<id> <lines> attempting|confirmed" shape is read forward:
# `confirmed` there counted only for the confirmed phase, and an `attempting`
# record proved nothing.
_away_ledger_chat_parse() {  # <state>  -> "<id> <confirmed> <from> <to>"
  local id a b c extra
  IFS=' ' read -r id a b c extra \
    < <(head -n 1 "$(away_ledger_chat_of "$1")" 2>/dev/null || true)
  [ -z "${extra:-}" ] || { printf 'none 0 0 0\n'; return 0; }
  case "${id:-}" in
    ''|*[!0-9a-zA-Z-]*) printf 'none 0 0 0\n'; return 0 ;;
  esac
  if [ -n "${c:-}" ]; then
    if away_ledger_is_count "${a:-}" "${b:-}" "$c"; then
      printf '%s %s %s %s\n' "$id" "$a" "$b" "$c"
      return 0
    fi
  elif away_ledger_is_count "${a:-}"; then
    case "${b:-}" in
      confirmed) printf '%s %s 0 0\n' "$id" "$a"; return 0 ;;
      attempting) printf '%s 0 0 %s\n' "$id" "$a"; return 0 ;;
    esac
  fi
  printf 'none 0 0 0\n'
}

# The receipt names its own batch, so it stays usable when the ledger sidecar
# itself is unreadable: a caller with no id (or the placeholder `none`) adopts
# the recorded identity rather than clobbering it with a nameless record.
_away_ledger_chat_effective_id() {  # <recorded-id> <requested-id>
  case "${2:-}" in
    ''|none) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

# Open an attempt on the (from, to] suffix. The confirmed prefix is carried
# forward untouched for the same batch, so this transition can only ever add
# information about what is in flight.
away_ledger_chat_mark_attempt() {  # <state> <batch-id> <from> <to>
  local state=$1 id=$2 from=$3 to=$4 rec rid rconfirmed rfrom rto confirmed
  away_ledger_is_count "$from" "$to" || return 1
  rec=$(_away_ledger_chat_parse "$state")
  IFS=' ' read -r rid rconfirmed rfrom rto <<< "$rec"
  id=$(_away_ledger_chat_effective_id "$rid" "$id")
  case "$id" in
    ''|none|*[!0-9a-zA-Z-]*) return 1 ;;
  esac
  confirmed=0
  [ "$id" = "$rid" ] && confirmed=$rconfirmed
  [ "$from" -ge "$confirmed" ] || from=$confirmed
  away_ledger_transact "$state" "$state/.subsuper-escalations" \
    "$(away_ledger_wedge_of "$state")" _away_ledger_mut_chat "$id" "$confirmed" "$from" "$to"
}

# A verified submit advances the confirmed prefix and closes the attempt. The
# advance is monotonic: a stale or smaller count can never walk it back.
away_ledger_chat_mark_confirmed() {  # <state> <batch-id> <to>
  local state=$1 id=$2 to=$3 rec rid rconfirmed rfrom rto confirmed
  away_ledger_is_count "$to" || return 1
  rec=$(_away_ledger_chat_parse "$state")
  IFS=' ' read -r rid rconfirmed rfrom rto <<< "$rec"
  id=$(_away_ledger_chat_effective_id "$rid" "$id")
  case "$id" in
    ''|none|*[!0-9a-zA-Z-]*) return 1 ;;
  esac
  confirmed=$to
  if [ "$id" = "$rid" ] && [ "$rconfirmed" -gt "$confirmed" ]; then
    confirmed=$rconfirmed
  fi
  away_ledger_transact "$state" "$state/.subsuper-escalations" \
    "$(away_ledger_wedge_of "$state")" _away_ledger_mut_chat "$id" "$confirmed" 0 0
}

# How many lines of <batch-id> captain chat PROVABLY already received. A batch
# only ever grows, so the prefix is monotonic and a later flush may only ever
# offer chat the lines PAST it. <batch-id> is optional: passing nothing (or the
# placeholder `none` a caller uses when the sidecar is unreadable) answers for
# whichever batch the receipt itself names, so an unreadable ledger over-reports
# only the lines chat has NOT been shown.
away_ledger_chat_delivered() {  # <state> [batch-id]
  local rec rid rconfirmed rfrom rto
  rec=$(_away_ledger_chat_parse "$1")
  IFS=' ' read -r rid rconfirmed rfrom rto <<< "$rec"
  [ "$rid" != none ] || { printf '0\n'; return 0; }
  case "${2:-}" in
    ''|none) ;;
    "$rid") ;;
    *) printf '0\n'; return 0 ;;
  esac
  printf '%s\n' "$rconfirmed"
}

_away_ledger_mut_wedge() {  # <text-file> <staging>
  cp -p "$1" "$2/wedge" 2>/dev/null
}

_away_ledger_mut_wedge_clear() {  # <staging>
  rm -f -- "$1/wedge" 2>/dev/null
}

# Capture the lines in (<from>, <to>] into this delivery's private digest inside
# the successor version and advance the accounted count in the SAME version, so a
# digested line and the count that accounts for it are never separately visible.
_away_ledger_mut_digest() {  # <delivery-id> <from> <to> <staging>
  local did=$1 from=$2 to=$3 staging=$4 lines rec migrated id reserved confirmed accounted attempt retry current
  [ -s "$staging/escalations" ] || return 0
  lines=$(( $(wc -l < "$staging/escalations" 2>/dev/null || echo 0) ))
  [ "$to" -le "$lines" ] || return 1
  [ "$to" -gt "$from" ] || return 0
  (umask 077; mkdir -p "$staging/tg-away-digest" 2>/dev/null) || return 1
  if ! (umask 077; sed -n "$((from + 1)),${to}p" "$staging/escalations" \
      > "$staging/tg-away-digest/$did.items") 2>/dev/null; then
    return 1
  fi
  rec=$(away_ledger_parse "$staging/escalations")
  [ "$rec" != unknown ] || return 1
  IFS=' ' read -r migrated id reserved confirmed accounted attempt retry current <<< "$rec"
  accounted=$to
  [ "$accounted" -le "$confirmed" ] || accounted=$confirmed
  _away_ledger_record_put "$staging/escalations" "$id" "$reserved" "$confirmed" \
    "$accounted" "$attempt" "$retry" "$did"
}

# PURE parse: print "<needs-migration> <batch-id> <reserved> <confirmed>
# <accounted> <attempt> <retry-after> <delivery-id>", or the single word
# `unknown` when the record is absent, malformed, or violates the
# accounted <= confirmed <= reserved invariant. Writes NOTHING, so it is the only
# record reader safe to point at a published immutable version. Every earlier
# record shape is normalised here and flagged as needing migration rather than
# rejected:
#   1 field   the pre-ledger bare arrival epoch  -> minted identity, zero counts
#   5 fields  id reserved confirmed accounted did -> attempt 0, retry-after 0
#   6 fields  ... attempt did                     -> retry-after 0
away_ledger_parse() {  # <buf>
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
  printf '%s %s %s %s %s %s %s %s\n' \
    "$migrated" "$id" "$reserved" "$confirmed" "$accounted" "$attempt" "$retry" "$did"
}

# The read-only record view: the normalised record with no migration write at
# all. Every reader that must not mutate its subject - the return catch-up's fold
# of a published immutable version above all - goes through this, never through
# away_ledger_read.
away_ledger_peek() {  # <buf>
  local rec
  rec=$(away_ledger_parse "$1")
  [ "$rec" != unknown ] || { printf 'unknown\n'; return 0; }
  printf '%s\n' "${rec#* }"
}

# The LIVE record view: parse, and migrate an earlier record shape in place so an
# in-place daemon upgrade during a live away session keeps its counts. Only ever
# pointed at a live buffer, never at a version directory - a published version is
# immutable, and a successor version is where a migrated record belongs.
away_ledger_read() {  # <buf>
  local buf=$1 rec migrated id reserved confirmed accounted attempt retry did
  rec=$(away_ledger_parse "$buf")
  [ "$rec" != unknown ] || { printf 'unknown\n'; return 0; }
  IFS=' ' read -r migrated id reserved confirmed accounted attempt retry did <<< "$rec"
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
  local state=$1 buf=$2 did=$3 from=$4 to=$5
  away_ledger_is_count "$from" "$to" || return 1
  [ -s "$buf" ] || return 0
  [ "$to" -gt "$from" ] || return 0
  away_ledger_transact "$state" "$buf" "$(away_ledger_wedge_of "$state")" \
    _away_ledger_mut_digest "$did" "$from" "$to"
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
# spool, any ledger temp, and any abandoned version-store staging directory
# (never a published version - those are retired only through
# away_ledger_version_retire / away_ledger_versions_retire_all). The text-free
# <id>.status delivery evidence is deliberately kept, so accepted/failed/
# unavailable outcomes stay auditable.
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
        "$state"/.subsuper-escalations.since.* \
        "$state"/.subsuper-escalations.apply.* \
        "$state"/.subsuper-inject-wedged.apply.* \
        "$state"/.subsuper-inject-wedged.stage.* \
        "$state"/.subsuper-chat-delivery.apply.* \
        "$state"/.mint.* 2>/dev/null
  rm -rf "$(away_ledger_versions_dir "$state")"/.staging.* \
         "$state"/.tg-away-digest.apply.* 2>/dev/null
  return 0
}

# --------------------------------------------------------------------------
# The immutable versioned batch store.
#
# The complete owned artifact unit for one away batch transaction is the
# escalation buffer, its ledger sidecar, the wedge marker, and the private
# digest directory - every artifact a crash or a failed re-entry must resume
# exactly once from. The text-free <id>.status delivery evidence is NEVER part
# of this unit: it outlives every version of the batch above it, so
# accepted/failed/unavailable outcomes stay auditable regardless of how many
# batches come and go over it.
#
# A version is one COMPLETE copy of that unit in its own directory under
# state/tg-away-versions:
#
#   .staging.XXXXXX/   a private in-progress build. Never listed, never read,
#                      never activated; swept as an away working record.
#   v.<epoch>-<nonce>/ a published version. Built in staging, validated against
#                      its own manifest, and made visible by ONE rename, so a
#                      crash can only ever leave a staging directory behind,
#                      never a half-built version. The `.complete` marker
#                      written last inside staging is the readable proof of
#                      that, and any v.* directory lacking it is treated as
#                      incomplete: ignored by every reader and swept by
#                      away_ledger_version_gc.
#   active             the single owner-controlled pointer naming the version
#                      the live unit must hold. Written atomically, and that
#                      write IS the commit point of a switch.
#   active.applied     the version whose content has already been materialised
#                      onto the live paths. active != active.applied means a
#                      switch is still pending and is replayed, so an
#                      interrupted switch converges instead of leaving the live
#                      unit half-installed.
#   .owner.lock        the store's own owner lock. Publishing, switching,
#                      materialising, and retiring all run while exactly one
#                      process holds it, so the two away entry paths (the
#                      launcher and a direct daemon start, which share no other
#                      lock) can never interleave.
#
# Nothing is ever copied or merged INTO a published version, and no individual
# file is ever merged into the live unit: a switch installs one version's whole
# unit or leaves the live unit entirely alone, so a version's sidecar counts can
# never be paired with a foreign buffer.
#
# A published version is immutable in the strict sense: every reader of one goes
# through away_ledger_peek, which parses without ever writing, so not even the
# legacy-record-shape migration can touch it. That migration belongs to successor
# construction instead - away_ledger_version_publish normalises the record inside
# its private staging copy - so versions always carry a current-shape record and
# the live sidecar the copy came from is left exactly as the daemon owns it.
#
# EVERY ledger transition is a version transition, the daemon's own included: the
# escalation append, the phone reservation, the evidence-proven acceptance, the
# retired attempt and its retry schedule, the digest plus the accounted count it
# advances, the wedge evidence, and the in-session truncation all go through
# away_ledger_transact. It takes the owner lock, copies the live unit into private
# staging, applies exactly ONE change there, validates and publishes the complete
# successor, switches the active pointer, and only then rewrites the live paths
# from a version that is already durable. No transition writes a live artifact as
# its source of truth, so the live unit is always a projection of some committed
# version - never state invented outside one - and a crash leaves either the
# predecessor active or a committed successor whose projection is replayed.
#
# The superseded predecessor is retired as soon as its successor is applied, since
# the successor was built from it and holds everything it held. A retained version
# that is NOT the chain's predecessor - a lifecycle entry capture, a rollback whose
# switch was refused - is never touched by a transition and retires only once the
# return catch-up is acknowledged.
#
# A switch is only ever performed while no live away daemon holds the
# supervise-daemon lock - checked inside this owner (away_ledger_daemon_live)
# rather than trusted to callers, and reported as rc 3. The daemon is the sole
# writer of the live buffer and its sidecar with no shared lock around them, so
# installing a unit under a running daemon would overwrite a freshly appended
# escalation that had never been reserved, digested, or shown in captain chat.
# Callers therefore only ever switch BEFORE daemon start; a refused switch
# leaves every version untouched and the return catch-up folds them instead.
#
# Versions are read - never mutated - by away_ledger_fold_versions at return,
# and retired as WHOLE versions only once that catch-up is acknowledged.

away_ledger_versions_dir() {  # <state>
  printf '%s\n' "$1/tg-away-versions"
}

# A published version name: minted by this owner, never derived from a live
# basename, and validated on every read so a pointer can only ever address a
# version directory inside the store.
away_ledger_version_name_valid() {  # <name>
  case "${1:-}" in
    v.*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!a-zA-Z0-9.-]*) return 1 ;;
  esac
  return 0
}

away_ledger_version_is_complete() {  # <version-dir>
  [ -n "${1:-}" ] && [ -d "$1" ] && [ -f "$1/.complete" ] && [ -f "$1/manifest" ]
}

away_ledger_version_path() {  # <state> <name>
  away_ledger_version_name_valid "${2:-}" || return 1
  printf '%s\n' "$(away_ledger_versions_dir "$1")/$2"
}

# Whether a live away daemon holds the supervise-daemon lock right now. Derived
# from <state> alone - never from a caller-supplied claim - and fail-closed: an
# owner whose recorded pid is alive counts as live, so an ambiguous lock refuses
# a pointer switch rather than racing a possible writer.
away_ledger_daemon_live() {  # <state>
  local lock="$1/.supervise-daemon.lock" owner pid
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) ;;
      *) owner="$1/$owner" ;;
    esac
  elif [ -d "$lock" ]; then
    owner=$lock
  else
    return 1
  fi
  pid=$(head -n 1 "$owner/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# The store's own owner lock. Every mutation of the store - publishing a version,
# switching the active pointer, materialising it, retiring a version - happens
# while exactly one process holds it, so two away entries (the launcher and a
# direct daemon start, which do not share the launcher's lock) can never
# interleave a publication with a pointer switch. A lock whose recorded pid is
# gone is reclaimed, but only ever through the steal lock below, so two acquirers
# that both observed the same dead holder cannot both remove and both create - the
# race that would hand the store to two owners at once and let a publish interleave
# with a materialise. An incomplete lock is given a bounded grace first, so a
# racing acquirer's own half-written lock is never ripped out from under it.
away_ledger_lock_acquire() {  # <versions-dir>
  local dir=$1 lock="$1/.owner.lock" attempt=0 incomplete=0 pid stale me
  me=${BASHPID:-$$}
  (umask 077; mkdir -p "$dir" 2>/dev/null) || return 1
  # Reentrant for the SAME process only, with a bounded depth. The daemon's
  # TERM/INT cleanup runs its final flush inside this same shell, so without this
  # a signal arriving mid-transaction would make every shutdown transition spin
  # against a lock this process already holds - a stalled shutdown and a lost
  # final flush. Exclusion against other processes is unchanged, and the recorded
  # identity is re-verified against the lock on disk, so a lock lost or stolen in
  # between is never treated as still held.
  if [ "${AWAY_LEDGER_LOCK_DEPTH:-0}" -gt 0 ] \
    && [ "${AWAY_LEDGER_LOCK_DIR:-}" = "$dir" ] \
    && [ "${AWAY_LEDGER_LOCK_OWNER:-}" = "$me" ] \
    && [ "$(head -n 1 "$lock/pid" 2>/dev/null || true)" = "$me" ]; then
    [ "$AWAY_LEDGER_LOCK_DEPTH" -lt 8 ] || return 1
    AWAY_LEDGER_LOCK_DEPTH=$((AWAY_LEDGER_LOCK_DEPTH + 1))
    return 0
  fi
  while [ "$attempt" -lt 200 ]; do
    attempt=$((attempt + 1))
    if mkdir "$lock" 2>/dev/null; then
      if ! printf '%s\n' "$me" > "$lock/pid" 2>/dev/null; then
        rm -rf -- "$lock" 2>/dev/null
        return 1
      fi
      AWAY_LEDGER_LOCK_DIR=$dir
      AWAY_LEDGER_LOCK_OWNER=$me
      AWAY_LEDGER_LOCK_DEPTH=1
      return 0
    fi
    pid=$(head -n 1 "$lock/pid" 2>/dev/null || true)
    stale=0
    case "$pid" in
      ''|*[!0-9]*)
        incomplete=$((incomplete + 1))
        if [ "$incomplete" -lt 20 ]; then
          sleep 0.05
          continue
        fi
        stale=1
        ;;
      *)
        incomplete=0
        kill -0 "$pid" 2>/dev/null || stale=1
        ;;
    esac
    if [ "$stale" -eq 1 ]; then
      _away_ledger_lock_steal "$lock" "$pid"
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  return 1
}

# Reclaim a lock whose holder is provably gone, under a lock of its own. The
# holder identity is RE-READ while the steal lock is held: whoever loses the steal
# race then sees either no lock at all or a different (new) holder, and removes
# nothing. A steal lock whose own holder died is reclaimed the same way once,
# without recursing, so a reclaimer that died mid-steal cannot wedge the store.
_away_ledger_lock_steal() {  # <lock-dir> <observed-pid>
  local lock=$1 observed=$2 steal="$1.steal" holder current
  if ! mkdir "$steal" 2>/dev/null; then
    holder=$(head -n 1 "$steal/pid" 2>/dev/null || true)
    case "$holder" in
      ''|*[!0-9]*) rm -rf -- "$steal" 2>/dev/null ;;
      *) kill -0 "$holder" 2>/dev/null || rm -rf -- "$steal" 2>/dev/null ;;
    esac
    return 0
  fi
  printf '%s\n' "${BASHPID:-$$}" > "$steal/pid" 2>/dev/null || true
  current=$(head -n 1 "$lock/pid" 2>/dev/null || true)
  if [ "$current" = "$observed" ]; then
    case "$current" in
      ''|*[!0-9]*) rm -rf -- "$lock" 2>/dev/null ;;
      *) kill -0 "$current" 2>/dev/null || rm -rf -- "$lock" 2>/dev/null ;;
    esac
  fi
  rm -rf -- "$steal" 2>/dev/null
  return 0
}

# Release one nesting level; the lock itself is only dropped by the outermost
# release, so a nested transition can never unlock the transaction containing it.
away_ledger_lock_release() {  # <versions-dir>
  local dir=$1 lock="$1/.owner.lock" me
  me=${BASHPID:-$$}
  if [ "${AWAY_LEDGER_LOCK_DEPTH:-0}" -gt 0 ] && [ "${AWAY_LEDGER_LOCK_DIR:-}" = "$dir" ] \
    && [ "${AWAY_LEDGER_LOCK_OWNER:-}" = "$me" ]; then
    AWAY_LEDGER_LOCK_DEPTH=$((AWAY_LEDGER_LOCK_DEPTH - 1))
    [ "$AWAY_LEDGER_LOCK_DEPTH" -eq 0 ] || return 0
    AWAY_LEDGER_LOCK_DIR=''
    AWAY_LEDGER_LOCK_OWNER=''
  fi
  [ "$(head -n 1 "$lock/pid" 2>/dev/null || true)" = "$me" ] || return 0
  rm -rf -- "$lock" 2>/dev/null
  return 0
}

# Same-directory mktemp plus mv, so a reader never sees a half-written pointer.
# The temp lives under the store's own .pointer. prefix, so it can never be
# mistaken for a version and is swept by away_ledger_version_gc.
away_ledger_pointer_write() {  # <versions-dir> active|active.applied <name>
  local dir=$1 base=$2 name=$3 tmp
  away_ledger_version_name_valid "$name" || return 1
  case "$base" in
    active|active.applied) ;;
    *) return 1 ;;
  esac
  tmp=$(umask 077; mktemp "$dir/.pointer.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$name" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$dir/$base" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null
    return 1
  fi
  return 0
}

away_ledger_pointer_read() {  # <pointer-file>
  local name
  name=$(head -n 1 "${1:-}" 2>/dev/null || true)
  away_ledger_version_name_valid "$name" || return 1
  printf '%s\n' "$name"
}

# Publish the CURRENT live unit as one new immutable version and print its name.
# Built entirely inside a private staging directory, validated against the
# manifest it wrote, marked complete, and published by a single rename - so a
# failure or a crash at any point leaves only staging behind and never a
# partially published version a later caller could activate.
away_ledger_version_publish() {  # <state> <buf> <wedge>
  local state=$1 buf=$2 wedge=$3 dir rc
  dir=$(away_ledger_versions_dir "$state")
  fmx_private_artifact_dir_prepare "$dir" >/dev/null 2>&1 || return 1
  away_ledger_lock_acquire "$dir" || return 1
  _away_ledger_version_publish_locked "$state" "$buf" "$wedge"
  rc=$?
  away_ledger_lock_release "$dir"
  return "$rc"
}

_away_ledger_version_publish_locked() {  # <state> <buf> <wedge>
  local state=$1 buf=$2 wedge=$3 built staging
  built=$(_away_ledger_stage_build "$state" "$buf" "$wedge") || return 1
  staging=${built#*	}
  [ -n "$staging" ] && [ -d "$staging" ] || return 1
  _away_ledger_stage_commit "$state" "$staging"
}

# Copy the current live unit into a fresh private staging directory and print it.
# This is the ONLY reader of the live unit inside a transaction, so a successor
# version always starts from a complete, self-consistent copy of one unit rather
# than from artifacts gathered at different moments.
_away_ledger_stage_build() {  # <state> <buf> <wedge>
  local state=$1 buf=$2 wedge=$3 dir staging digest_dir slot artifact base
  local -a artifacts slots
  dir=$(away_ledger_versions_dir "$state")
  staging=$(umask 077; mktemp -d "$dir/.staging.XXXXXX" 2>/dev/null) || return 1
  # Preferred base: the immutable active predecessor directory itself, so the
  # successor is provably that version plus one transition - which is also what
  # makes retiring the predecessor sound. Only used when the live unit is
  # provably still that version's projection; a unit that diverged (an
  # interrupted projection, or a writer outside this owner) is staged from live
  # instead, so divergence is captured into the successor rather than discarded.
  base=$(away_ledger_pointer_read "$dir/active" 2>/dev/null || true)
  if [ -n "$base" ] \
    && [ "$base" = "$(away_ledger_pointer_read "$dir/active.applied" 2>/dev/null || true)" ] \
    && away_ledger_version_is_complete "$dir/$base" \
    && _away_ledger_unit_matches_version "$state" "$buf" "$wedge" "$dir/$base"; then
    if ! cp -pR "$dir/$base/." "$staging/" 2>/dev/null \
      || ! rm -f -- "$staging/manifest" "$staging/.complete" 2>/dev/null; then
      rm -rf -- "$staging" 2>/dev/null
      return 1
    fi
    printf '%s\t%s\n' "$base" "$staging"
    return 0
  fi
  artifacts=()
  while IFS= read -r artifact; do artifacts+=("$artifact"); done \
    < <(_away_ledger_unit_paths "$state" "$buf" "$wedge")
  slots=()
  while IFS= read -r slot; do slots+=("$slot"); done < <(_away_ledger_unit_slots)
  local i=0
  while [ "$i" -lt "${#slots[@]}" ]; do
    artifact=${artifacts[$i]}
    slot=${slots[$i]}
    i=$((i + 1))
    [ -e "$artifact" ] || continue
    if ! cp -p "$artifact" "$staging/$slot" 2>/dev/null; then
      rm -rf -- "$staging" 2>/dev/null
      return 1
    fi
  done
  digest_dir=$(away_ledger_digest_dir "$state")
  if [ -d "$digest_dir" ]; then
    if ! cp -pR "$digest_dir" "$staging/tg-away-digest" 2>/dev/null; then
      rm -rf -- "$staging" 2>/dev/null
      return 1
    fi
  fi
  printf '\t%s\n' "$staging"
  return 0
}

# Whether the live unit is still exactly <version-dir>'s projection: every single
# file present-and-identical or absent on both sides, and the same digest item
# names. Anything else means something diverged after the projection.
_away_ledger_unit_matches_version() {  # <state> <buf> <wedge> <version-dir>
  local state=$1 buf=$2 wedge=$3 vdir=$4 slot artifact digest_dir i
  local -a artifacts slots
  artifacts=()
  while IFS= read -r artifact; do artifacts+=("$artifact"); done \
    < <(_away_ledger_unit_paths "$state" "$buf" "$wedge")
  slots=()
  while IFS= read -r slot; do slots+=("$slot"); done < <(_away_ledger_unit_slots)
  i=0
  while [ "$i" -lt "${#slots[@]}" ]; do
    artifact=${artifacts[$i]}
    slot=${slots[$i]}
    i=$((i + 1))
    if [ -e "$vdir/$slot" ]; then
      [ -f "$artifact" ] || return 1
      cmp -s "$vdir/$slot" "$artifact" || return 1
    else
      [ ! -e "$artifact" ] || return 1
    fi
  done
  digest_dir=$(away_ledger_digest_dir "$state")
  if [ -d "$vdir/tg-away-digest" ]; then
    [ -d "$digest_dir" ] || return 1
    [ "$(cd "$vdir/tg-away-digest" && ls -1 2>/dev/null | sort)" \
      = "$(cd "$digest_dir" && ls -1 2>/dev/null | sort)" ] || return 1
  else
    [ ! -d "$digest_dir" ] || return 1
  fi
  return 0
}

# Validate a staged unit, describe it in its own manifest, mark it complete, and
# publish it by ONE rename - printing the published name. The manifest is written
# from the slots actually present, so it can never drift from what a mutator left
# behind, and the cross-pairing check refuses a record with no buffer to count.
#
# An earlier record shape is normalised HERE, in private staging: this is the only
# place that migration ever happens, so no published version and no live sidecar is
# ever rewritten by a read. A record that cannot be parsed at all is left exactly
# as found and published as-is: the version becomes the immutable quarantine of
# that malformed state, the fold over-reports from the whole buffer (never dropping
# an owed line), and away-mode entry is never wedged by unreadable predecessor
# bookkeeping.
_away_ledger_stage_commit() {  # <state> <staging>
  local state=$1 staging=$2 dir slot name rec
  local migrated id reserved confirmed accounted attempt retry did
  dir=$(away_ledger_versions_dir "$state")
  if [ -e "$staging/escalations.since" ] && [ ! -e "$staging/escalations" ]; then
    rm -rf -- "$staging" 2>/dev/null
    return 1
  fi
  if [ -e "$staging/escalations.since" ]; then
    rec=$(away_ledger_parse "$staging/escalations")
    if [ "$rec" != unknown ]; then
      IFS=' ' read -r migrated id reserved confirmed accounted attempt retry did <<< "$rec"
      if [ "$migrated" -eq 1 ] \
        && ! _away_ledger_record_put "$staging/escalations" "$id" "$reserved" "$confirmed" \
          "$accounted" "$attempt" "$retry" "$did"; then
        rm -rf -- "$staging" 2>/dev/null
        return 1
      fi
    fi
  fi
  if ! : > "$staging/manifest" 2>/dev/null; then
    rm -rf -- "$staging" 2>/dev/null
    return 1
  fi
  for slot in escalations escalations.since wedge chat tg-away-digest; do
    [ -e "$staging/$slot" ] || continue
    if ! printf '%s\n' "$slot" >> "$staging/manifest" 2>/dev/null; then
      rm -rf -- "$staging" 2>/dev/null
      return 1
    fi
  done
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    if [ ! -e "$staging/$slot" ]; then
      rm -rf -- "$staging" 2>/dev/null
      return 1
    fi
  done < "$staging/manifest"
  if ! : > "$staging/.complete" 2>/dev/null; then
    rm -rf -- "$staging" 2>/dev/null
    return 1
  fi
  name="v.$(away_ledger_mint_id "$dir")"
  # Never rename ONTO an existing entry: mv would move the staging directory
  # inside it, leaving the predecessor published as though it were the successor.
  if [ -e "$dir/$name" ] || ! mv "$staging" "$dir/$name" 2>/dev/null; then
    rm -rf -- "$staging" 2>/dev/null
    return 1
  fi
  printf '%s\n' "$name"
  return 0
}

# ONE ledger transition: under the owner lock, copy the live unit into private
# staging, let <mutator> apply exactly one change to that copy, validate and
# publish it as a complete successor version, switch the active pointer atomically,
# and only then rewrite the live projection from the version that is already
# durable. A crash at any point leaves either the predecessor still active or a
# committed successor whose projection the next apply replays - never a live unit
# invented outside a version.
#
# The superseded predecessor is retired once the successor is applied: the
# successor was built from it and is a complete superset, so nothing that was
# evidence is discarded. Retained versions that are NOT this chain's predecessor -
# a lifecycle entry capture, a refused rollback - are never touched here and still
# retire only once the return catch-up is acknowledged.
away_ledger_transact() {  # <state> <buf> <wedge> <mutator> [args...]
  local state=$1 buf=$2 wedge=$3 dir rc
  shift 3
  dir=$(away_ledger_versions_dir "$state")
  fmx_private_artifact_dir_prepare "$dir" >/dev/null 2>&1 || return 1
  away_ledger_lock_acquire "$dir" || return 1
  _away_ledger_transact_locked "$state" "$buf" "$wedge" "$@"
  rc=$?
  away_ledger_lock_release "$dir"
  return "$rc"
}

_away_ledger_transact_locked() {  # <state> <buf> <wedge> <mutator> [args...]
  local state=$1 buf=$2 wedge=$3 dir staging name previous built
  shift 3
  dir=$(away_ledger_versions_dir "$state")
  built=$(_away_ledger_stage_build "$state" "$buf" "$wedge") || return 1
  previous=${built%%	*}
  staging=${built#*	}
  [ -n "$staging" ] && [ -d "$staging" ] || return 1
  if ! "$@" "$staging"; then
    rm -rf -- "$staging" 2>/dev/null
    return 1
  fi
  name=$(_away_ledger_stage_commit "$state" "$staging") || return 1
  away_ledger_pointer_write "$dir" active "$name" || return 1
  away_ledger_version_materialise "$state" "$buf" "$wedge" "$dir/$name" || return 1
  away_ledger_pointer_write "$dir" active.applied "$name" || return 1
  # Only the version this successor was actually BUILT from is retired, so the
  # superset claim is proven rather than assumed: a successor staged from a
  # diverged live unit leaves its predecessor retained for the return fold, which
  # already collapses identical lines.
  if [ -n "$previous" ] && [ "$previous" != "$name" ] \
    && [ -d "$dir/$previous" ]; then
    rm -rf -- "$dir/$previous" 2>/dev/null || true
  fi
  return 0
}

# Every COMPLETE published version, oldest first (the minted name carries the
# publication epoch). An incomplete directory is never listed, so no reader can
# act on a version that was never validated.
away_ledger_version_names() {  # <state>
  local dir v name
  dir=$(away_ledger_versions_dir "$1")
  [ -d "$dir" ] || return 0
  for v in "$dir"/v.*; do
    away_ledger_version_is_complete "$v" || continue
    name=${v##*/}
    away_ledger_version_name_valid "$name" || continue
    printf '%s\n' "$name"
  done | sort
  return 0
}

# Drop everything the store must never act on: abandoned staging builds, leaked
# pointer temps, any version directory that is not provably complete, and any
# pointer left aiming at a version that is gone or was never completed. Never
# touches a complete version or a pointer that still resolves, so it is safe to run
# at any moment, including while a daemon is live.
#
# Clearing a dangling pointer is the only forward path: the content it named no
# longer exists, and leaving it would make every later apply - and so every away
# entry - refuse for good. Referenced evidence is preserved by construction, since
# a pointer is only ever cleared when the version it names is provably absent or
# incomplete.
away_ledger_version_gc() {  # <state>
  local dir v pointer name result=0
  dir=$(away_ledger_versions_dir "$1")
  [ -d "$dir" ] || return 0
  away_ledger_lock_acquire "$dir" || return 1
  rm -rf -- "$dir"/.staging.* 2>/dev/null
  rm -f -- "$dir"/.pointer.* "$dir"/.mint.* 2>/dev/null
  for v in "$dir"/v.*; do
    [ -e "$v" ] || continue
    away_ledger_version_is_complete "$v" && continue
    rm -rf -- "$v" 2>/dev/null || result=1
  done
  for pointer in active active.applied; do
    [ -e "$dir/$pointer" ] || continue
    name=$(away_ledger_pointer_read "$dir/$pointer" 2>/dev/null || true)
    if [ -n "$name" ] && away_ledger_version_is_complete "$dir/$name"; then
      continue
    fi
    rm -f -- "$dir/$pointer" 2>/dev/null || result=1
  done
  away_ledger_lock_release "$dir"
  return "$result"
}

# THE pointer switch, and the only way a version's content ever reaches the live
# paths. Refuses an unknown or incomplete version (rc 1) and refuses outright
# while a live daemon holds the lock (rc 3); either way every version and the
# live unit are left exactly as they were.
away_ledger_version_activate() {  # <state> <buf> <wedge> <name>
  local state=$1 buf=$2 wedge=$3 name=$4 dir vdir rc
  vdir=$(away_ledger_version_path "$state" "$name") || return 1
  away_ledger_version_is_complete "$vdir" || return 1
  if away_ledger_daemon_live "$state"; then
    return 3
  fi
  dir=$(away_ledger_versions_dir "$state")
  away_ledger_lock_acquire "$dir" || return 1
  if away_ledger_pointer_write "$dir" active "$name"; then
    _away_ledger_version_apply_locked "$state" "$buf" "$wedge"
    rc=$?
  else
    rc=1
  fi
  away_ledger_lock_release "$dir"
  return "$rc"
}

# Replay a switch whose materialisation has not completed. Idempotent: with no
# pointer, or with the pointer already applied, it is a no-op. Callers run it
# before daemon start so an interrupted switch converges; it refuses (rc 3)
# while a daemon is live, so it can never race the daemon's own writes.
away_ledger_version_apply_pending() {  # <state> <buf> <wedge>
  local state=$1 buf=$2 wedge=$3 dir rc
  dir=$(away_ledger_versions_dir "$state")
  [ -d "$dir" ] || return 0
  away_ledger_lock_acquire "$dir" || return 1
  _away_ledger_version_apply_locked "$state" "$buf" "$wedge"
  rc=$?
  away_ledger_lock_release "$dir"
  return "$rc"
}

_away_ledger_version_apply_locked() {  # <state> <buf> <wedge>
  local state=$1 buf=$2 wedge=$3 dir name applied vdir
  dir=$(away_ledger_versions_dir "$state")
  [ -d "$dir" ] || return 0
  name=$(away_ledger_pointer_read "$dir/active") || return 0
  applied=$(away_ledger_pointer_read "$dir/active.applied" 2>/dev/null || true)
  [ "$name" != "$applied" ] || return 0
  vdir="$dir/$name"
  away_ledger_version_is_complete "$vdir" || return 1
  if away_ledger_daemon_live "$state"; then
    return 3
  fi
  away_ledger_version_materialise "$state" "$buf" "$wedge" "$vdir" || return 1
  away_ledger_pointer_write "$dir" active.applied "$name"
}

# Install ONE version's whole unit onto the live paths, dropping whatever is
# there first, so no live artifact is ever left paired with a foreign version's
# counts. Every file lands through a same-directory mktemp-then-mv and the
# digest directory through a staged rename, so a reader elsewhere can never
# observe a half-copied artifact. A failure leaves the pointer unapplied, which
# is what makes the replay above safe to re-run.
away_ledger_version_materialise() {  # <state> <buf> <wedge> <version-dir>
  local state=$1 buf=$2 wedge=$3 vdir=$4 digest_dir slot artifact tmp i
  local -a artifacts slots
  artifacts=()
  while IFS= read -r artifact; do artifacts+=("$artifact"); done \
    < <(_away_ledger_unit_paths "$state" "$buf" "$wedge")
  slots=()
  while IFS= read -r slot; do slots+=("$slot"); done < <(_away_ledger_unit_slots)
  digest_dir=$(away_ledger_digest_dir "$state")
  rm -f -- "${artifacts[@]}" 2>/dev/null || return 1
  rm -rf -- "$digest_dir" 2>/dev/null || return 1
  i=0
  while [ "$i" -lt "${#slots[@]}" ]; do
    artifact=${artifacts[$i]}
    slot=${slots[$i]}
    i=$((i + 1))
    [ -e "$vdir/$slot" ] || continue
    tmp=$(umask 077; mktemp "${artifact}.apply.XXXXXX" 2>/dev/null) || return 1
    if ! cp -p "$vdir/$slot" "$tmp" 2>/dev/null || ! mv -f "$tmp" "$artifact" 2>/dev/null; then
      rm -f -- "$tmp" 2>/dev/null
      return 1
    fi
  done
  if [ -d "$vdir/tg-away-digest" ]; then
    tmp=$(umask 077; mktemp -d "$state/.tg-away-digest.apply.XXXXXX" 2>/dev/null) || return 1
    if ! cp -pR "$vdir/tg-away-digest/." "$tmp/" 2>/dev/null \
      || ! chmod 700 "$tmp" 2>/dev/null \
      || ! mv "$tmp" "$digest_dir" 2>/dev/null; then
      rm -rf -- "$tmp" 2>/dev/null
      return 1
    fi
  fi
  return 0
}

# Retire ONE whole version. Any pointer naming it is cleared FIRST, so a crash
# can never leave a pointer aimed at a version that no longer exists.
away_ledger_version_retire() {  # <state> <name>
  local state=$1 name=$2 dir vdir pointer current result=0
  vdir=$(away_ledger_version_path "$state" "$name") || return 1
  dir=$(away_ledger_versions_dir "$state")
  [ -d "$dir" ] || return 0
  away_ledger_lock_acquire "$dir" || return 1
  for pointer in active active.applied; do
    current=$(away_ledger_pointer_read "$dir/$pointer" 2>/dev/null || true)
    [ "$current" = "$name" ] || continue
    rm -f -- "$dir/$pointer" 2>/dev/null || result=1
  done
  rm -rf -- "$vdir" 2>/dev/null || result=1
  away_ledger_lock_release "$dir"
  return "$result"
}

# Retire the WHOLE version store. Called only once a return catch-up has been
# acknowledged: every version's actionable content has reached that catch-up's
# durable evidence by then, so nothing retired here can resurface as a duplicate
# delivery, and nothing is retired while a catch-up is still pending.
away_ledger_versions_retire_all() {  # <state>
  local dir name result=0
  dir=$(away_ledger_versions_dir "$1")
  [ -d "$dir" ] || return 0
  away_ledger_lock_acquire "$dir" || return 1
  rm -f -- "$dir/active" "$dir/active.applied" "$dir"/.pointer.* "$dir"/.mint.* 2>/dev/null \
    || result=1
  rm -rf -- "$dir"/v.* "$dir"/.staging.* 2>/dev/null || result=1
  # Removal is only acknowledged when the store is provably empty of versions and
  # pointers: a caller that keeps a gate open on this status must not be told the
  # catch-up is settled while a version survives to be folded again.
  while IFS= read -r name; do
    [ -z "$name" ] || result=1
  done <<EOF
$(away_ledger_version_names "$1")
EOF
  [ ! -e "$dir/active" ] || result=1
  away_ledger_lock_release "$dir"
  rmdir "$dir" 2>/dev/null || true
  return "$result"
}

# The ONE entry-boundary transaction every away entry goes through - the launcher
# and a direct daemon start alike - printing the name of the version it captured.
# Sweep what was never published, replay an interrupted pointer switch (the only
# moment a version's content may reach the live paths, and refused by the owner
# while a daemon is live), then capture the predecessor unit as one complete
# immutable version.
#
# A caller retires the live unit ONLY after this has succeeded, so no entry path
# can delete a crashed session's un-flushed escalation lines with no surviving
# copy - the evidence-loss class this store exists to close. Because the capture
# lives here rather than in one caller, a future entry path cannot skip it by
# omission.
away_ledger_entry_capture() {  # <state> <buf> <wedge>
  local state=$1 buf=$2 wedge=$3 rc=0
  away_ledger_version_gc "$state" || true
  away_ledger_version_apply_pending "$state" "$buf" "$wedge" || rc=$?
  [ "$rc" -ne 1 ] || return 1
  away_ledger_version_publish "$state" "$buf" "$wedge"
}

# Print the lines of <buf> that no digest has accounted for yet, one per line -
# the lines that still have to reach captain chat. Falls back to the whole
# buffer whenever the record is absent or `unknown`, so an unreadable ledger
# over-reports to the visible catch-up instead of dropping a captain-relevant
# line.
#
# Reads through away_ledger_peek, never away_ledger_read: this runs against
# published immutable versions as well as the live buffer, and a migrating read
# would both break that immutability and - if the migration write failed - report
# `unknown` and re-offer lines the version's own digests already carry.
away_ledger_unaccounted_lines() {  # <buf>
  local buf=$1 rec accounted=0 n
  [ -s "$buf" ] || return 0
  if [ -f "${buf}.since" ]; then
    rec=$(away_ledger_peek "$buf" 2>/dev/null || true)
    if [ -n "$rec" ] && [ "$rec" != unknown ]; then
      IFS=' ' read -r _ _ _ accounted _ _ _ <<< "$rec"
      away_ledger_is_count "$accounted" || accounted=0
    fi
  fi
  n=$(( $(wc -l < "$buf" 2>/dev/null || echo 0) ))
  [ "$n" -gt "$accounted" ] || return 0
  tail -n "+$((accounted + 1))" "$buf" 2>/dev/null || return 1
  return 0
}

# Print ONE kind of actionable content held by every RETAINED version, so a
# version whose switch was refused (a live daemon, a failed stop), whose
# transaction was abandoned, or whose content a fresh away entry retired from the
# live paths still reaches the return catch-up instead of ageing out silently.
#
# Read-only: nothing is retired, renamed, or marked here, so a crash mid
# catch-up simply re-reads the same versions next time, and the retirement that
# eventually removes them happens only after acknowledgement.
#
# One kind per call, so a caller can append each to the SAME evidence kind its
# own live read uses. That is what makes each logical escalation appear exactly
# once: a version's content is a prefix-subset of the live unit whenever the live
# unit was materialised from it, and identical lines under one evidence kind
# collapse in the caller's own dedupe instead of being presented twice under two
# different labels.
#
#   escalations  the lines past each version's OWN accounted count - never
#                anything that version's own digests already carry.
#   wedges       each version's wedge marker line.
#   digests      each version's digest items whose delivery id is not already
#                live, since one delivery id always names the same text.
away_ledger_fold_versions() {  # <state> escalations|wedges|digests
  local state=$1 kind=$2 dir name vdir digest_dir f base
  case "$kind" in
    escalations|wedges|digests) ;;
    *) return 1 ;;
  esac
  dir=$(away_ledger_versions_dir "$state")
  [ -d "$dir" ] || return 0
  digest_dir=$(away_ledger_digest_dir "$state")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    vdir="$dir/$name"
    case "$kind" in
      escalations)
        away_ledger_unaccounted_lines "$vdir/escalations" || return 1
        ;;
      wedges)
        if [ -s "$vdir/wedge" ]; then
          head -n 1 "$vdir/wedge" 2>/dev/null || return 1
        fi
        ;;
      digests)
        for f in "$vdir"/tg-away-digest/*.items; do
          [ -f "$f" ] || continue
          base=${f##*/}
          if [ -e "$digest_dir/$base" ]; then
            continue
          fi
          cat "$f" 2>/dev/null || return 1
        done
        ;;
    esac
  done <<EOF
$(away_ledger_version_names "$state")
EOF
  return 0
}

# Retire the complete owned unit for a lifecycle boundary (a fresh away entry, a
# mid-session restart, or a completed return catch-up): the escalation buffer,
# the wedge marker, the ledger sidecar, and this session's working records. The
# version store is deliberately NOT touched here - a launch transaction calls
# this while its own rollback version is the only surviving copy of the prior
# unit.
#
# <preserve-digests>, when 1, keeps the digest directory intact (see
# away_ledger_retire_working_records) - callers pass 1 on a continuation of an
# already-active away session rather than a genuinely fresh entry.
away_ledger_retire_batch() {  # <state> <buf> <wedge> [preserve-digests]
  local state=$1 buf=$2 wedge=$3 preserve=${4:-0} dir result=0
  rm -f "$buf" "$wedge" "$(away_ledger_chat_of "$state")" 2>/dev/null || result=1
  away_ledger_retire "$buf" || result=1
  away_ledger_retire_working_records "$state" "$preserve" || result=1
  # The retired unit is no longer any version's projection, so the chain head is
  # cleared too: the next transition stages a fresh unit instead of resurrecting a
  # retired batch from a stale active pointer. The version DIRECTORIES stay - they
  # are the evidence the return catch-up folds and only acknowledgement retires.
  dir=$(away_ledger_versions_dir "$state")
  if [ -d "$dir" ]; then
    if away_ledger_lock_acquire "$dir"; then
      rm -f -- "$dir/active" "$dir/active.applied" 2>/dev/null || result=1
      away_ledger_lock_release "$dir"
    else
      result=1
    fi
  fi
  return "$result"
}
