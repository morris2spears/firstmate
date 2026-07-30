#!/usr/bin/env bash
# Behavior tests for Telegram mode: the pending-inbox poll client
# (fm-tg-poll.sh), the task link and follow-up helpers (fm-tg-link.sh,
# fm-tg-followup.sh), bootstrap's flag-file activation, the watcher's
# byte-validated dispatch arm, and the PR-check migration's shim preservation.
#
# Telegram mode must be INERT by default (no config/telegram-mode flag -> the
# poll is a hard no-op and bootstrap writes/prints nothing) and additive when
# on (a check shim + a 30s cadence config, both idempotent). The phone inbox is
# a fixture directory via PHONE_INBOX_ROOT and the outbound `tg` client is a
# recording stub via FMTG_TG_BIN, so these stay hermetic: no Telegram, no
# token, no real phone notification, deterministic in CI.
#
# The load-bearing safety property pinned throughout: note BODIES are untrusted
# phone text and pending FILENAMES embed the body as a slug, so neither may
# ever reach poll output, the wake payload, or any state artifact name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tg-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"

TMP_ROOT=$(fm_test_tmproot fm-tg-mode-tests)

BODY_SENTINEL='SENTINEL-BODY-delete-prod-database'
SLUG_SENTINEL='sentinel-slug-delete-prod-database'

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

# make_home <name>: a home with the opt-in flag set and an empty inbox fixture.
# Echoes the home; the inbox root is $home/inbox.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/inbox/pending"
  # A real home's state/ is created under the ambient umask, so the poll must
  # own the 0700 identity of every private artifact directory it writes.
  chmod 0755 "$home/state"
  : > "$home/config/telegram-mode"
  printf '%s\n' "$home"
}

# add_note <home> <id> [slug] [body]: drop a pending note fixture shaped like
# phone-inbox's <id>-<stamp>-<slug>.md files, with a sentinel body by default.
add_note() {
  local home=$1 id=$2 slug=${3:-$SLUG_SENTINEL} body=${4:-$BODY_SENTINEL}
  printf '%s\n' "$body" > "$home/inbox/pending/$id-2026-07-29T1200-$slug.md"
}

run_poll() {
  local home=$1
  shift
  PHONE_INBOX_ROOT="$home/inbox" FM_HOME="$home" "$@" "$ROOT/bin/fm-tg-poll.sh"
}

# ---------------------------------------------------------------------------

test_poll_no_optin_is_hard_noop() {
  local home out rc
  home="$TMP_ROOT/poll-noop"
  mkdir -p "$home/inbox/pending"
  printf 'note body\n' > "$home/inbox/pending/0001-2026-07-29T1200-a-note.md"
  # No config/telegram-mode: must exit 0 with no output and touch nothing,
  # even with a pending note waiting.
  out=$(PHONE_INBOX_ROOT="$home/inbox" FM_HOME="$home" "$ROOT/bin/fm-tg-poll.sh"); rc=$?
  expect_code 0 "$rc" "poll no-optin exit"
  [ -z "$out" ] || fail "poll without opt-in must be silent (got: $out)"
  assert_absent "$home/state/tg-offered" "poll without opt-in must not create offer markers"
  assert_absent "$home/state/tg-poll" "poll without opt-in must not create error state"
  pass "fm-tg-poll is a hard no-op without the opt-in flag (inert default)"
}

test_poll_emits_ids_only_never_note_text() {
  local home out rc
  home=$(make_home poll-ids-only)
  add_note "$home" 0042
  out=$(run_poll "$home"); rc=$?
  expect_code 0 "$rc" "poll ids-only exit"
  [ "$out" = "tg-message 0042" ] || fail "poll must emit exactly the id wake payload (got: $out)"
  assert_not_contains "$out" "$BODY_SENTINEL" "note body leaked into poll output"
  assert_not_contains "$out" "$SLUG_SENTINEL" "filename slug leaked into poll output"
  assert_present "$home/state/tg-offered/0042" "poll must record the offered marker under the bare id"
  # No state artifact may carry the slug or body either (marker names are ids).
  if find "$home/state" -name "*$SLUG_SENTINEL*" | grep . >/dev/null; then
    fail "filename slug leaked into a state artifact name"
  fi
  pass "fm-tg-poll emits note ids only - never bodies, never filename slugs"
}

test_poll_multiple_ids_one_line() {
  local home out
  home=$(make_home poll-multi)
  add_note "$home" 0007 first-note
  add_note "$home" 0009 second-note
  out=$(run_poll "$home")
  [ "$out" = "tg-message 0007 0009" ] || fail "poll must coalesce ids into one line (got: $out)"
  pass "fm-tg-poll offers multiple pending notes in one wake line"
}

test_poll_offers_once_then_silent() {
  local home out
  home=$(make_home poll-once)
  add_note "$home" 0042
  out=$(run_poll "$home")
  [ "$out" = "tg-message 0042" ] || fail "first poll must offer the note (got: $out)"
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "second poll must stay silent for an already offered note (got: $out)"
  pass "fm-tg-poll offers a note exactly once while its marker is fresh"
}

test_poll_reoffers_stale_unclaimed_note() {
  local home out
  home=$(make_home poll-reoffer)
  add_note "$home" 0042
  out=$(run_poll "$home" env FMTG_NOW_OVERRIDE=1000000)
  [ "$out" = "tg-message 0042" ] || fail "first poll must offer the note (got: $out)"
  # Still fresh inside the window: silent.
  out=$(run_poll "$home" env FMTG_NOW_OVERRIDE=1000000)
  [ -z "$out" ] || fail "fresh marker must stay silent (got: $out)"
  # Age the marker past the re-offer window via its mtime.
  touch -t 202001010000 "$home/state/tg-offered/0042"
  out=$(run_poll "$home")
  [ "$out" = "tg-message 0042" ] || fail "stale unclaimed note must be re-offered (got: $out)"
  # The re-offer refreshed the marker, so the next poll is silent again.
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "re-offered marker must be fresh again (got: $out)"
  pass "fm-tg-poll re-offers a note still unclaimed after the re-offer window"
}

test_poll_prunes_markers_for_gone_notes() {
  local home out
  home=$(make_home poll-prune)
  add_note "$home" 0042
  run_poll "$home" >/dev/null
  assert_present "$home/state/tg-offered/0042" "marker must exist after the offer"
  # The note is claimed/archived: it leaves pending, and the marker follows.
  rm "$home/inbox/pending/"0042-*.md
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "poll after claim must be silent (got: $out)"
  assert_absent "$home/state/tg-offered/0042" "marker for a gone note must be pruned"
  pass "fm-tg-poll prunes offered markers when their note leaves pending"
}

test_poll_missing_inbox_reports_once() {
  local home out
  home="$TMP_ROOT/poll-missing-inbox"
  mkdir -p "$home/config" "$home/state"
  # An ordinary umask-created state/, not a 0700 one: the dedupe record must
  # still persist, or the error re-emits on every poll of the 30s cadence.
  chmod 0755 "$home/state"
  : > "$home/config/telegram-mode"
  out=$(PHONE_INBOX_ROOT="$home/no-such-inbox" FM_HOME="$home" "$ROOT/bin/fm-tg-poll.sh")
  assert_contains "$out" "tg-mode-error missing phone inbox" "opted-in poll must surface a missing inbox"
  assert_present "$home/state/tg-poll/error" "the inbox error dedupe record must persist under a umask-created state dir"
  out=$(PHONE_INBOX_ROOT="$home/no-such-inbox" FM_HOME="$home" "$ROOT/bin/fm-tg-poll.sh")
  [ -z "$out" ] || fail "the same inbox error must be reported once, not every poll (got: $out)"
  # Recovery clears the dedupe record so a later failure reports again.
  mkdir -p "$home/no-such-inbox/pending"
  out=$(PHONE_INBOX_ROOT="$home/no-such-inbox" FM_HOME="$home" "$ROOT/bin/fm-tg-poll.sh")
  [ -z "$out" ] || fail "a recovered inbox with no notes must be silent (got: $out)"
  assert_absent "$home/state/tg-poll/error" "recovery must clear the error dedupe record"
  pass "fm-tg-poll reports a missing inbox once and recovers silently"
}

test_poll_ignores_malformed_filenames() {
  local home out
  home=$(make_home poll-malformed)
  printf 'x\n' > "$home/inbox/pending/not-a-note.md"
  printf 'x\n' > "$home/inbox/pending/no-extension"
  printf 'x\n' > "$home/inbox/pending/.hidden.md"
  out=$(run_poll "$home")
  [ -z "$out" ] || fail "malformed pending filenames must not wake firstmate (got: $out)"
  pass "fm-tg-poll ignores files without a leading numeric note id"
}

test_shim_validation_accepts_only_exact_private_identity() {
  local home shim
  home=$(make_home shim-validate)
  shim="$home/state/tg-watch.check.sh"
  fmtg_poll_shim_content "$home" "$ROOT" > "$shim"
  chmod 0700 "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" || fail "exact generated shim must validate"
  # One extra byte: reject.
  printf '#\n' >> "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "tampered shim bytes must be rejected"
  # Right bytes, wrong mode: reject.
  fmtg_poll_shim_content "$home" "$ROOT" > "$shim"
  chmod 0755 "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "a 0755 shim must be rejected"
  chmod 0700 "$shim"
  # A second hard link: reject.
  ln "$shim" "$home/state/shim-alias"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "a multi-link shim must be rejected"
  rm "$home/state/shim-alias"
  # A symlink: reject.
  mv "$shim" "$home/state/shim-target"
  ln -s "$home/state/shim-target" "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "a symlinked shim must be rejected"
  # Wrong home in the bytes: reject.
  rm "$shim"
  fmtg_poll_shim_content "$TMP_ROOT/other-home" "$ROOT" > "$shim"
  chmod 0700 "$shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" && fail "a shim generated for another home must be rejected"
  pass "fmtg_poll_shim_valid accepts only the exact single-link 0700 identity"
}

test_bootstrap_inert_without_optin() {
  local home out
  # No config/ at all.
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMTG:" "bootstrap must say nothing about Telegram mode without the flag"
  assert_absent "$home/state/tg-watch.check.sh" "no flag -> no check shim"
  assert_absent "$home/config/tg-mode.env" "no flag -> no cadence config"
  # A symlinked flag is not opt-in.
  home="$TMP_ROOT/boot-symlink-flag"; mkdir -p "$home/config"
  printf 'x\n' > "$home/flag-target"
  ln -s "$home/flag-target" "$home/config/telegram-mode"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMTG:" "a symlinked flag must be treated as off"
  assert_absent "$home/state/tg-watch.check.sh" "symlinked flag -> no check shim"
  pass "bootstrap is inert without a regular opt-in flag file (fresh clones unaffected)"
}

test_bootstrap_activates_on_optin_flag() {
  local home out sum1 sum2 n inherited
  home="$TMP_ROOT/boot-on"; mkdir -p "$home/config"
  : > "$home/config/telegram-mode"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMTG: Telegram mode on" "bootstrap must announce Telegram mode"
  assert_present "$home/state/tg-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/tg-watch.check.sh" ] || fail "the check shim must be executable"
  assert_grep "fm-tg-poll.sh" "$home/state/tg-watch.check.sh" "the shim must exec the poll script"
  assert_present "$home/config/tg-mode.env" "bootstrap must drop the cadence config"
  assert_grep "export FM_CHECK_INTERVAL=30" "$home/config/tg-mode.env" "cadence must be 30s"
  # shellcheck source=/dev/null
  inherited=$( . "$home/config/tg-mode.env" && bash -c 'echo "${FM_CHECK_INTERVAL:-300}"' )
  [ "$inherited" = "30" ] \
    || fail "sourcing the cadence config must export FM_CHECK_INTERVAL=30 to a child"
  # Idempotent: re-running (which also re-runs the PR-check migration against
  # the now-present shim) changes nothing and does not quarantine the shim.
  sum1=$(cat "$home/state/tg-watch.check.sh" "$home/config/tg-mode.env" | shasum)
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/tg-watch.check.sh" "$home/config/tg-mode.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap Telegram-mode setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'tg-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap activates Telegram mode from the flag file, idempotently"
}

test_bootstrap_opt_out_cleanup() {
  local home out
  home="$TMP_ROOT/boot-optout"; mkdir -p "$home/config"
  : > "$home/config/telegram-mode"
  FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_present "$home/state/tg-watch.check.sh" "activation must arm the shim first"
  rm "$home/config/telegram-mode"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FMTG: Telegram mode off - removed inbox poll shim" \
    "bootstrap must announce the opt-out cleanup"
  assert_absent "$home/state/tg-watch.check.sh" "opt-out must remove the check shim"
  assert_absent "$home/config/tg-mode.env" "opt-out must remove the cadence config"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "FMTG:" "steady-state off must be silent"
  pass "bootstrap removes Telegram artifacts on opt-out and is then silent"
}

test_bootstrap_does_not_follow_tg_artifact_symlinks() {
  local home shim_target cadence_target out
  home="$TMP_ROOT/boot-linked-artifacts"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/telegram-mode"
  shim_target="$home/external-shim"
  cadence_target="$home/external-cadence"
  printf 'external shim sentinel\n' > "$shim_target"
  printf 'external cadence sentinel\n' > "$cadence_target"
  chmod 0640 "$shim_target" "$cadence_target"
  ln -s "$shim_target" "$home/state/tg-watch.check.sh"
  ln -s "$cadence_target" "$home/config/tg-mode.env"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FMTG: Telegram mode off - failed to arm inbox poll shim or 30s cadence" \
    "bootstrap must reject linked Telegram-mode destinations"
  assert_not_contains "$out" "FMTG: Telegram mode on" \
    "bootstrap must not announce Telegram mode after rejecting linked destinations"
  [ "$(cat "$shim_target")" = 'external shim sentinel' ] \
    || fail "bootstrap changed the linked shim target"
  [ "$(cat "$cadence_target")" = 'external cadence sentinel' ] \
    || fail "bootstrap changed the linked cadence target"
  [ "$(path_mode "$shim_target")" = 640 ] \
    || fail "bootstrap changed the linked shim target mode"
  assert_absent "$home/state/tg-watch.check.sh" "bootstrap must remove the rejected shim link"
  assert_absent "$home/config/tg-mode.env" "bootstrap must remove the rejected cadence link"
  pass "bootstrap rejects linked Telegram artifacts without touching their targets"
}

test_migration_preserves_valid_tg_shim() {
  local home shim
  home=$(make_home migrate-preserve)
  shim="$home/state/tg-watch.check.sh"
  fmtg_poll_shim_content "$home" "$ROOT" > "$shim"
  chmod 0700 "$shim"
  FM_HOME="$home" "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 \
    || fail "migration failed with a valid Telegram shim armed"
  assert_present "$shim" "migration must not quarantine a byte-valid Telegram shim"
  fmtg_poll_shim_valid "$shim" "$home" "$ROOT" \
    || fail "migration changed the valid Telegram shim"
  ! find "$home/state/.pr-check-quarantine" -name 'tg-watch.check.*' -type f 2>/dev/null | grep . >/dev/null \
    || fail "valid Telegram shim was quarantined"
  # And the --checks-safe watcher gate accepts the armed home.
  FM_HOME="$home" "$ROOT/bin/fm-pr-check-migrate.sh" --checks-safe >/dev/null 2>&1 \
    || fail "--checks-safe rejected a home with only a valid Telegram shim"
  pass "the PR-check migration preserves a byte-valid Telegram shim"
}

test_migration_neutralizes_tampered_tg_shim() {
  local home shim executed
  home=$(make_home migrate-tampered)
  shim="$home/state/tg-watch.check.sh"
  executed="$home/tampered-executed"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'touch %s\n' "$executed"
  } > "$shim"
  chmod 0700 "$shim"
  FM_HOME="$home" "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 || true
  [ ! -e "$executed" ] || fail "migration executed a tampered Telegram shim"
  assert_absent "$shim" "a tampered Telegram shim must not remain armed"
  pass "the PR-check migration neutralizes a tampered Telegram shim without executing it"
}

# Run the real watcher, bounded, against a home whose only check is the tg shim.
run_watcher_bounded() {
  local home=$1 inbox=$2
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" PHONE_INBOX_ROOT="$inbox" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "$ROOT/bin/fm-watch.sh"
}

test_watcher_dispatches_valid_tg_shim_end_to_end() {
  local home out rc
  home=$(make_home watch-dispatch)
  add_note "$home" 0042
  fmtg_poll_shim_content "$home" "$ROOT" > "$home/state/tg-watch.check.sh"
  chmod 0700 "$home/state/tg-watch.check.sh"
  out=$(run_watcher_bounded "$home" "$home/inbox" 2>/dev/null)
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher never woke for a pending note"
  assert_contains "$out" "tg-message 0042" "watcher wake must carry the note id"
  assert_not_contains "$out" "$BODY_SENTINEL" "note body leaked into the watcher wake"
  assert_not_contains "$out" "$SLUG_SENTINEL" "filename slug leaked into the watcher wake"
  assert_grep "tg-message 0042" "$home/state/.wake-queue" "durable wake record must carry the id"
  assert_no_grep "$BODY_SENTINEL" "$home/state/.wake-queue" "note body leaked into the durable wake queue"
  assert_no_grep "$SLUG_SENTINEL" "$home/state/.wake-queue" "filename slug leaked into the durable wake queue"
  pass "the real watcher dispatches the valid Telegram shim and wakes with ids only"
}

test_watcher_rejects_tampered_tg_shim() {
  local home out rc executed
  home=$(make_home watch-reject)
  add_note "$home" 0042
  executed="$home/tampered-executed"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'touch %s\n' "$executed"
  } > "$home/state/tg-watch.check.sh"
  chmod 0700 "$home/state/tg-watch.check.sh"
  out=$(run_watcher_bounded "$home" "$home/inbox" 2>/dev/null)
  rc=$?
  [ "$rc" -ge 0 ] || fail "watcher run failed to return"
  [ ! -e "$executed" ] || fail "watcher executed a tampered Telegram shim"
  assert_not_contains "$out" "tg-message" "a tampered shim must never produce a note wake"
  pass "the real watcher never executes a tampered Telegram shim"
}

test_link_records_note_and_timestamp() {
  local home meta out
  home="$TMP_ROOT/link-basic"; mkdir -p "$home/state"
  meta="$home/state/task-a.meta"
  fm_write_meta "$meta" "window=w" "project=p"
  out=$(FM_HOME="$home" FMTG_NOW_OVERRIDE=1234 "$ROOT/bin/fm-tg-link.sh" task-a 0042)
  assert_contains "$out" "linked task-a to telegram note 0042" "link must confirm"
  assert_grep "tg_note=0042" "$meta" "link must record the note id"
  assert_grep "tg_note_ts=1234" "$meta" "link must record the timestamp"
  assert_grep "tg_followups=0" "$meta" "a fresh link must start the counter at 0"
  assert_grep "window=w" "$meta" "link must preserve other meta lines"
  # Relink with carry preserves budget and window.
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" task-a 0042 --carry-count 2 --carry-ts 999 >/dev/null
  assert_grep "tg_followups=2" "$meta" "carry must preserve the consumed count"
  assert_grep "tg_note_ts=999" "$meta" "carry must preserve the original window"
  pass "fm-tg-link records and carries the note link in task meta"
}

test_link_rejects_unsafe_and_missing() {
  local home rc
  home="$TMP_ROOT/link-unsafe"; mkdir -p "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" '../evil' 0042 2>/dev/null; rc=$?
  expect_code 2 "$rc" "unsafe task id"
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" task-a 'evil/../id' 2>/dev/null; rc=$?
  expect_code 2 "$rc" "unsafe note id"
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" task-a 0042 2>/dev/null; rc=$?
  expect_code 1 "$rc" "missing meta"
  FM_HOME="$home" "$ROOT/bin/fm-tg-link.sh" task-a 0042 --carry-count 1 2>/dev/null; rc=$?
  expect_code 2 "$rc" "carry-count without carry-ts"
  pass "fm-tg-link rejects unsafe ids, missing tasks, and unpaired carry flags"
}

make_fake_tg() {
  local dir=$1
  cat > "$dir/tg" <<SH
#!/usr/bin/env bash
cat >> '$dir/tg-sent.log'
printf '\n---\n' >> '$dir/tg-sent.log'
exit "\${FAKE_TG_EXIT:-0}"
SH
  chmod +x "$dir/tg"
  printf '%s\n' "$dir/tg"
}

test_followup_lifecycle() {
  local home meta tg out rc
  home="$TMP_ROOT/followup"; mkdir -p "$home/state"
  meta="$home/state/task-a.meta"
  tg=$(make_fake_tg "$home")

  # Unlinked task: --check is a silent exit-1 no-op.
  fm_write_meta "$meta" "window=w"
  FM_HOME="$home" "$ROOT/bin/fm-tg-followup.sh" --check task-a >/dev/null; rc=$?
  expect_code 1 "$rc" "unlinked check"

  # Linked and fresh: check prints the note id.
  FM_HOME="$home" FMTG_NOW_OVERRIDE=1000 "$ROOT/bin/fm-tg-link.sh" task-a 0042 >/dev/null
  out=$(FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 "$ROOT/bin/fm-tg-followup.sh" --check task-a)
  [ "$out" = "0042" ] || fail "due check must print the note id (got: $out)"

  # A send reads stdin/file only and pipes the text to tg on stdin.
  printf 'first milestone update' > "$home/reply.txt"
  FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" \
    "$ROOT/bin/fm-tg-followup.sh" task-a --text-file "$home/reply.txt" >/dev/null \
    || fail "first follow-up send failed"
  assert_grep "first milestone update" "$home/tg-sent.log" "tg must receive the text on stdin"
  assert_grep "tg_followups=1" "$meta" "a successful send must increment the counter"

  # A failed send leaves the counter and link untouched.
  printf 'failing update' | FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" FAKE_TG_EXIT=1 \
    "$ROOT/bin/fm-tg-followup.sh" task-a - >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failed tg send must exit non-zero"
  assert_grep "tg_followups=1" "$meta" "a failed send must not increment the counter"
  assert_grep "tg_note=0042" "$meta" "a failed send must keep the link"

  # --final always clears the link.
  printf 'done: shipped' | FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" \
    "$ROOT/bin/fm-tg-followup.sh" task-a --final - >/dev/null \
    || fail "final follow-up send failed"
  assert_no_grep "tg_note=" "$meta" "--final must clear the link"

  # Reaching the cap clears the link after the send.
  FM_HOME="$home" FMTG_NOW_OVERRIDE=1000 "$ROOT/bin/fm-tg-link.sh" task-a 0042 --carry-count 2 --carry-ts 1000 >/dev/null
  printf 'third update' | FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" \
    "$ROOT/bin/fm-tg-followup.sh" task-a - >/dev/null || fail "cap-reaching send failed"
  assert_no_grep "tg_note=" "$meta" "reaching the cap must clear the link"

  # An expired window prunes on check without sending.
  FM_HOME="$home" FMTG_NOW_OVERRIDE=1000 "$ROOT/bin/fm-tg-link.sh" task-a 0042 >/dev/null
  FM_HOME="$home" FMTG_NOW_OVERRIDE=99999999 "$ROOT/bin/fm-tg-followup.sh" --check task-a >/dev/null; rc=$?
  expect_code 1 "$rc" "expired check"
  assert_no_grep "tg_note=" "$meta" "an expired link must be pruned"

  # An empty follow-up is refused before reaching tg.
  FM_HOME="$home" FMTG_NOW_OVERRIDE=1000 "$ROOT/bin/fm-tg-link.sh" task-a 0042 >/dev/null
  printf '   ' | FM_HOME="$home" FMTG_NOW_OVERRIDE=2000 FMTG_TG_BIN="$tg" \
    "$ROOT/bin/fm-tg-followup.sh" task-a - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "empty follow-up refusal"
  pass "fm-tg-followup enforces the stdin-only, cap, window, and final-clear contract"
}

test_supervision_needed_by_tg_shim() {
  local home
  home="$TMP_ROOT/sup-needed"; mkdir -p "$home/state"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-supervision-lib.sh"
  fm_supervision_status "$home/state"
  [ "$FM_SUP_NEEDED" = false ] || fail "an empty home must not need supervision"
  : > "$home/state/tg-watch.check.sh"
  fm_supervision_status "$home/state"
  [ "$FM_SUP_NEEDED" = true ] || fail "a Telegram-armed home must need supervision with no fleet work"
  pass "fm_supervision_status counts the Telegram poll as supervision-needed"
}

# ledger_field <state> <field-index> <expected> <message>: assert one ledger count.
ledger_field() {
  local state=$1 idx=$2 want=$3 msg=$4 got
  got=$(away_ledger_read "$state/.subsuper-escalations" | cut -d' ' -f"$idx")
  [ "$got" = "$want" ] || fail "$msg (ledger field $idx = $got, want $want)"
}

# away_deliver <home> <state> [tg-bin] [fake-tg-exit]: drive telegram_away_deliver
# exactly the way escalate_flush does - read the ledger, hand it the pending body
# plus the current reserved/total/accounted counts and the batch id. Nothing may
# reach the phone without those, so tests go through the same door.
away_deliver() {
  local home=$1 state=$2 tg_bin=${3:-} fake_exit=${4:-0}
  local buf rec id reserved confirmed accounted did n pending
  buf="$state/.subsuper-escalations"
  rec=$(away_ledger_read "$buf")
  IFS=' ' read -r id reserved confirmed accounted did <<< "$rec"
  n=$(( $(wc -l < "$buf" 2>/dev/null || echo 0) ))
  pending=$(tail -n "+$((reserved + 1))" "$buf" 2>/dev/null \
    | awk 'NR>1{printf " | "} {printf "%s",$0} END{print ""}')
  (
    export FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live
    export FMTG_TG_BIN="$tg_bin" FAKE_TG_EXIT="$fake_exit"
    telegram_away_deliver "$state" "$pending" "$reserved" "$n" "$accounted" "$id"
  )
}

test_away_delivery_is_inert_outside_away_mode() {
  local home state tg out
  home=$(make_home away-inactive)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  printf '1700000000\n' > "$state/.subsuper-escalations.since"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
    FMTG_TG_BIN="$tg" telegram_away_deliver "$state" 'blocked: should stay in session')
  [ "$out" = 'off|none' ] || fail "Telegram away delivery must be off outside away mode (got: $out)"
  assert_absent "$home/tg-sent.log" "Telegram delivery outside away mode must not call the outbound client"
  assert_absent "$state/tg-away-delivery" "Telegram delivery outside away mode must not create evidence"
  pass "Telegram escalation delivery is inert outside away mode"
}

test_away_delivery_is_accepted_once_and_records_no_content() {
  local home state tg out first_id second_id
  home=$(make_home away-accepted)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  escalate_add "$state" 'needs-decision: approve privileged cutover'

  out=$(away_deliver "$home" "$state" "$tg")
  first_id=${out#*|}
  [ "${out%%|*}" = accepted ] || fail "away delivery must report accepted (got: $out)"

  # A repeat of the very same (batch, offset, body) delivery must re-derive the
  # same id, settle from the existing accepted evidence, and never produce a
  # second phone alert.
  away_ledger_write "$state/.subsuper-escalations" \
    "$(printf '%s' "$first_id" | cut -d- -f1-2)" 0 0 0 0 0 none \
    || fail "could not rewind the ledger for the repeat-delivery case"
  out=$(away_deliver "$home" "$state" "$tg")
  second_id=${out#*|}
  [ "${out%%|*}" = accepted ] || fail "accepted away delivery must remain accepted (got: $out)"
  [ "$first_id" = "$second_id" ] || fail "the same away batch must keep one delivery id"
  [ "$(grep -c '^---$' "$home/tg-sent.log")" -eq 1 ] \
    || fail "the same away batch reached the outbound client more than once"
  grep -Eq '^accepted [0-9]+$' "$state/tg-away-delivery/$first_id.status" \
    || fail "accepted delivery must have non-secret durable evidence"
  assert_no_grep 'privileged cutover' "$state/tg-away-delivery/$first_id.status" \
    "delivery evidence must not contain message text"
  pass "away delivery records Telegram acceptance and sends each batch exactly once"
}

test_away_delivery_failure_classes_and_safe_chat_fallback() {
  local home state tg out injected
  home=$(make_home away-failure)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"

  # A client that RAN and exited non-zero cannot be distinguished from a lost
  # response to an accepted send, so it is uncertain, not failed, and its
  # reservation is kept.
  escalate_add "$state" 'blocked: credential needed'
  out=$(away_deliver "$home" "$state" "$tg" 1)
  [ "${out%%|*}" = uncertain ] \
    || fail "a client that ran and rejected must report uncertain (got: $out)"
  grep -Eq '^failed [0-9]+ sender_uncertain_response$' "$state/tg-away-delivery/${out#*|}.status" \
    || fail "an uncertain delivery must have non-secret durable evidence"
  ledger_field "$state" 2 1 "an uncertain send must keep its phone reservation"
  ledger_field "$state" 3 0 "an uncertain send must not be confirmed"
  ledger_field "$state" 5 0 "an ambiguous outcome must never retire its attempt for retry"

  # A missing client provably never left the box: unavailable, reservation released.
  : > "$state/.subsuper-escalations"
  away_ledger_retire "$state/.subsuper-escalations"
  escalate_add "$state" 'blocked: second credential needed'
  out=$(away_deliver "$home" "$state" "$home/missing-tg")
  [ "${out%%|*}" = unavailable ] || fail "a missing Telegram client must report unavailable (got: $out)"
  grep -Eq '^unavailable [0-9]+ sender_missing$' "$state/tg-away-delivery/${out#*|}.status" \
    || fail "unavailable delivery must have non-secret durable evidence"
  ledger_field "$state" 2 0 "a send that never left the box must release its reservation"
  ledger_field "$state" 5 1 "a proven-local failure must retire its attempt for retry"

  : > "$state/.subsuper-escalations"
  away_ledger_retire "$state/.subsuper-escalations"
  escalate_add "$state" 'blocked: safe fallback required'
  injected="$home/injected.log"
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$home/missing-tg" escalate_flush "$state"
  ) || fail "failed Telegram delivery must retain the in-session fallback"
  assert_grep 'blocked: safe fallback required' "$injected" \
    "the fallback must preserve the captain-relevant escalation"
  assert_grep 'Telegram delivery unavailable; the captain was not contacted there' "$injected" \
    "the fallback must never claim Telegram delivery"
  pass "away delivery distinguishes failed and unavailable transport and falls back safely"
}

test_away_delivery_acceptance_does_not_duplicate_alert_in_chat() {
  local home state tg injected
  home=$(make_home away-no-chat-duplicate)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  printf 'needs-decision: approve privileged cutover\n' > "$state/.subsuper-escalations"
  printf '1700000004\n' > "$state/.subsuper-escalations.since"
  injected="$home/injected.log"

  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "accepted Telegram delivery must complete the away flush"

  assert_grep 'Telegram accepted away-mode alert' "$injected" \
    "Firstmate must receive a non-secret accepted receipt"
  assert_no_grep 'approve privileged cutover' "$injected" \
    "an accepted Telegram alert must not be duplicated into captain chat"
  assert_grep 'needs-decision: approve privileged cutover' "$home/tg-sent.log" \
    "the existing outbound client must receive the actual batched alert"
  assert_grep 'does not approve a merge, privileged change, destructive action, or security-sensitive action' "$home/tg-sent.log" \
    "the phone notice must preserve approval boundaries"
  [ ! -s "$state/.subsuper-escalations" ] || fail "confirmed receipt injection must clear the away buffer"
  pass "accepted away alerts reach Telegram once without duplicating their contents in captain chat"
}

test_away_batch_never_resends_accepted_events() {
  local home state tg injected sends pointer digests digest delivery_id
  home=$(make_home away-grown-batch)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"

  # First event: Telegram accepts it, but the in-session receipt is wedged, so
  # the buffer and its batch identity are preserved for retry.
  printf 'stale persisted 300s (possible wedge): fm-task-3\n' > "$state/.subsuper-escalations"
  printf '1700000010\n' > "$state/.subsuper-escalations.since"
  (
    inject_msg() { return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) && fail "a wedged receipt must leave escalate_flush unconfirmed"
  assert_grep 'fm-task-3' "$home/tg-sent.log" "the first event must reach the phone"

  # A second event appends while the receipt is still wedged. The phone must
  # receive ONLY the new event, never a repeat of the accepted one.
  printf 'needs-decision: approve privileged cutover\n' >> "$state/.subsuper-escalations"
  cp "$state/.subsuper-escalations" "$home/expected-items.txt"
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "the grown away batch must flush once the receipt lands"
  sends=$(grep -c '^---$' "$home/tg-sent.log")
  [ "$sends" -eq 2 ] || fail "the grown batch must reach the phone once per new event (got $sends sends)"
  [ "$(grep -c 'fm-task-3' "$home/tg-sent.log")" -eq 1 ] \
    || fail "an already-accepted away event must never be sent to the phone twice"
  assert_grep 'approve privileged cutover' "$home/tg-sent.log" \
    "the newly appended event must reach the phone"
  assert_no_grep 'approve privileged cutover' "$injected" \
    "an accepted away alert must not be duplicated into captain chat"
  [ ! -s "$state/.subsuper-escalations" ] || fail "the confirmed receipt must clear the away buffer"

  # The receipt must point at digests that actually exist and, together, hold
  # EVERY accepted item of the grown batch - not just the last delivery's - so a
  # one-shot escalation stays actionable after the buffer is truncated.
  pointer=$(sed -n 's|.*private away digests state/tg-away-digest/\([^ ;]*\)\.items.*|\1|p' "$injected")
  [ -n "$pointer" ] || fail "the accepted receipt must point at the batch digests"
  digests=$(eval ls "$state/tg-away-digest/$pointer.items" 2>/dev/null || true)
  [ -n "$digests" ] || fail "the receipt's digest pointer must match real files ($pointer)"
  for digest in $digests; do
    [ -f "$digest" ] && [ ! -L "$digest" ] || fail "a pointed-at digest must be a regular file"
    case "$(ls -l "$digest")" in
      -rw-------*) ;;
      *) fail "the away digest must be private (0600)" ;;
    esac
  done
  # shellcheck disable=SC2086
  [ "$(cat $digests | sort)" = "$(sort "$home/expected-items.txt")" ] \
    || fail "the pointed-at digests must hold exactly the accepted items of the batch"
  delivery_id=$(sed -n 's/^Telegram accepted away-mode alert \([^ ,]*\).*/\1/p' "$injected")
  assert_no_grep 'privileged cutover' "$state/tg-away-delivery/$delivery_id.status" \
    "delivery evidence must stay text-free"

  # A later failure must not repeat the events Telegram already delivered.
  printf 'blocked: credential needed\n' > "$state/.subsuper-escalations"
  printf '1700000020\n' > "$state/.subsuper-escalations.since"
  (
    inject_msg() { return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) && fail "a wedged receipt must leave the second batch unconfirmed"
  printf 'paused 600s (awaiting external): fm-task-9\n' >> "$state/.subsuper-escalations"
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" FAKE_TG_EXIT=1 escalate_flush "$state"
  ) || fail "a failed Telegram send must still complete the in-session fallback"
  assert_grep 'fm-task-9' "$injected" \
    "the undelivered event must reach the in-session fallback"
  assert_no_grep 'credential needed' "$injected" \
    "the fallback must not repeat an event Telegram already delivered"
  pass "an away batch that grows while the receipt is wedged never re-sends accepted events"
}

test_away_unusable_bookkeeping_never_sends_to_the_phone() {
  local home state tg injected
  home=$(make_home away-bad-bookkeeping)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"
  printf 'blocked: needs a decision\n' > "$state/.subsuper-escalations"
  printf 'not-a-batch record here\n' > "$state/.subsuper-escalations.since"

  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "unreadable bookkeeping must still complete the in-session flush"

  assert_absent "$home/tg-sent.log" \
    "unreadable away bookkeeping must never risk a duplicate phone alert"
  assert_grep 'blocked: needs a decision' "$injected" \
    "the visible in-session fallback must carry every buffered event"
  assert_grep 'ledger is unreadable' "$injected" \
    "the fallback must say why the phone was not contacted"
  pass "unusable away bookkeeping fails closed to the visible in-session fallback"
}

# The ledger reserves lines BEFORE the network call, so a reservation alone never
# proves the captain was contacted. A restart must resolve it from the durable
# delivery evidence: an unresolved attempt stays honestly uncertain and is never
# re-sent, while a reservation with no evidence at all is released so those lines
# can still reach the phone.
test_away_reserved_lines_resolve_from_evidence_not_from_the_claim() {
  local home state tg injected did
  home=$(make_home away-reserved-recovery)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"

  # (a) reserved with an unresolved `attempting` record: uncertain, never re-sent.
  printf 'blocked: mid-send crash\n' > "$state/.subsuper-escalations"
  did='1700000030-abcdef0123456789-0-0123456789abcdef'
  mkdir -p "$state/tg-away-delivery"
  chmod 0700 "$state/tg-away-delivery"
  printf 'attempting 1700000030\n' > "$state/tg-away-delivery/$did.status"
  chmod 0600 "$state/tg-away-delivery/$did.status"
  printf '1700000030-abcdef0123456789 1 0 0 0 0 %s\n' "$did" > "$state/.subsuper-escalations.since"
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "an uncertain reservation must still complete the in-session flush"
  assert_absent "$home/tg-sent.log" \
    "a reserved-but-unconfirmed line must never be re-sent to the phone"
  assert_grep 'Telegram delivery uncertain' "$injected" \
    "an unconfirmed reservation must never be reported as accepted"
  assert_grep 'blocked: mid-send crash' "$injected" \
    "the uncertain event must still reach the visible in-session fallback"

  # (a2) reserved with durable `accepted` evidence: the crash landed between the
  # send and the ledger commit, so recovery confirms it from the evidence and never
  # sends again.
  printf 'blocked: crashed after acceptance\n' > "$state/.subsuper-escalations"
  did='1700000035-abcdef0123456789-0-fedcba9876543210'
  printf 'accepted 1700000035\n' > "$state/tg-away-delivery/$did.status"
  chmod 0600 "$state/tg-away-delivery/$did.status"
  printf '1700000035-abcdef0123456789 1 0 0 0 0 %s\n' "$did" > "$state/.subsuper-escalations.since"
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "a recoverable acceptance must complete the away flush"
  assert_absent "$home/tg-sent.log" \
    "a line with durable accepted evidence must never be sent again"
  assert_grep 'Telegram accepted away-mode alert' "$injected" \
    "durable accepted evidence must be reported as accepted"

  # (b) reserved with no evidence at all: the claim is released and the line is
  # offered to the phone.
  printf 'blocked: crashed before the send\n' > "$state/.subsuper-escalations"
  printf '1700000040-fedcba9876543210 1 0 0 0 0 none\n' > "$state/.subsuper-escalations.since"
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "a released reservation must complete the away flush"
  assert_grep 'crashed before the send' "$home/tg-sent.log" \
    "a reservation with no delivery evidence must be released back to the phone"
  assert_grep 'Telegram accepted away-mode alert' "$injected" \
    "the re-offered event must report its real accepted outcome"
  pass "reserved away lines resolve from durable evidence, never from the claim alone"
}

# Turning Telegram mode off mid-batch must not replay into captain chat what the
# captain already received on his phone.
test_away_off_mid_batch_never_repeats_delivered_events() {
  local home state tg injected
  home=$(make_home away-off-mid-batch)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"
  escalate_add "$state" 'blocked: already on the phone'
  (
    inject_msg() { return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) && fail "a wedged receipt must leave escalate_flush unconfirmed"
  assert_grep 'already on the phone' "$home/tg-sent.log" "the first event must reach the phone"

  # Telegram mode is switched off, then a second event appends.
  rm "$home/config/telegram-mode"
  escalate_add "$state" 'blocked: after the opt-out'
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "an opted-out away flush must still deliver in session"
  assert_grep 'after the opt-out' "$injected" \
    "the undelivered event must reach captain chat once Telegram mode is off"
  assert_no_grep 'already on the phone' "$injected" \
    "an event the captain already received on his phone must not be replayed in chat"
  [ "$(grep -c '^---$' "$home/tg-sent.log")" -eq 1 ] \
    || fail "an opted-out flush must not contact the phone again"
  pass "an opt-out mid-batch never repeats phone-delivered events in captain chat"
}

test_away_lifecycle_retires_tg_working_records() {
  local home state
  home=$(make_home away-retirement)
  state="$home/state"
  mkdir -p "$state/tg-away-digest" "$state/tg-away-delivery"
  printf 'stale persisted 300s: fm-task-1\n' > "$state/tg-away-digest/abc.items"
  printf 'text' > "$state/tg-away-delivery/.spool.zzz"
  printf 'accepted 1700000000\n' > "$state/tg-away-delivery/abc.status"
  : > "$state/.subsuper-escalations.since.tmpXYZ"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1"; fm_afk_clear_stale_artifacts "$2"' _ "$ROOT/bin/fm-afk-start.sh" "$state" \
    || fail "the away-start clear must succeed"

  assert_absent "$state/tg-away-digest" \
    "the private away digest must retire with the away session"
  assert_absent "$state/tg-away-delivery/.spool.zzz" \
    "a leaked outbound spool must retire with the away session"
  assert_absent "$state/.subsuper-escalations.since.tmpXYZ" \
    "a leaked sidecar temp must retire with the away session"
  [ -f "$state/tg-away-delivery/abc.status" ] \
    || fail "durable text-free delivery evidence must outlive the away session"
  pass "the away lifecycle retires the Telegram working records and keeps the evidence"
}

# A launch rollback backup only survives past its own transaction when
# away_ledger_restore itself failed partway. away_ledger_reclaim_backups must
# fold any digest text such a backup holds into the live digest directory
# rather than let it age out silently, then remove the orphaned backup.
test_away_reclaim_backups_folds_orphaned_digest_text() {
  local home state backup live mode
  home=$(make_home away-reclaim-backups)
  state="$home/state"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  mkdir -p "$backup/tg-away-digest"
  printf 'blocked: stranded by an interrupted restore\n' \
    > "$backup/tg-away-digest/1700000000-abc-a0-0-x.items"

  away_ledger_reclaim_backups "$state" "$state/.subsuper-escalations" \
    "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*" \
    || fail "reclaim must succeed when the live digest directory is writable"

  live="$state/tg-away-digest/1700000000-abc-a0-0-x.items"
  [ -f "$live" ] \
    || fail "reclaim must fold the orphaned backup's digest text into the live digest directory"
  [ "$(cat "$live" 2>/dev/null)" = 'blocked: stranded by an interrupted restore' ] \
    || fail "reclaim must preserve the orphaned digest's exact text"
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$state/tg-away-digest" 2>/dev/null)
  else
    mode=$(stat -c %a "$state/tg-away-digest" 2>/dev/null)
  fi
  [ "$mode" = 700 ] \
    || fail "reclaim must create the live digest directory as a private 0700 dir (got: $mode)"
  assert_absent "$backup" "reclaim must remove the orphaned backup once its digest text is folded in"
  pass "reclaim folds an orphaned rollback backup's digest text and removes the backup"
}

# A backup can also hold the escalation buffer, its ledger sidecar, and the
# wedge marker - the artifacts an interrupted away_ledger_restore may have left
# missing on the live unit. Reclaim must fill those gaps too, never just the
# digest text, so a batch that was never digested is not silently discarded.
test_away_reclaim_backups_fills_missing_buffer_and_sidecar() {
  local home state backup buf
  home=$(make_home away-reclaim-buffer)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'blocked: never digested before the crash\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"
  printf 'wedged\n' > "$backup/.subsuper-inject-wedged"

  away_ledger_reclaim_backups "$state" "$buf" "$state/.subsuper-inject-wedged" \
    "$state/.afk-launch-backup.*" \
    || fail "reclaim must succeed when the live artifacts are simply missing"

  [ "$(cat "$buf" 2>/dev/null)" = 'blocked: never digested before the crash' ] \
    || fail "reclaim must fill in a missing escalation buffer from the backup"
  [ -f "${buf}.since" ] \
    || fail "reclaim must fill in a missing ledger sidecar from the backup"
  [ -f "$state/.subsuper-inject-wedged" ] \
    || fail "reclaim must fill in a missing wedge marker from the backup"
  assert_absent "$backup" "reclaim must remove the backup once every gap is filled"
  pass "reclaim fills a missing buffer, sidecar, and wedge marker from an orphaned backup"
}

# The buffer, its ledger sidecar, and the wedge marker are one opaque unit -
# the sidecar's counts are offsets into that exact buffer. When a live buffer
# already exists, reclaim must never gap-fill the backup's sidecar or wedge
# marker onto it (that would misattribute counts onto unrelated live escalation
# lines), and it must not discard the backup's own undigested buffer either -
# it must leave the whole group untouched and keep the backup intact for a
# later reclaim once the live unit clears.
test_away_reclaim_backups_never_mixes_a_live_buffer_with_a_foreign_group() {
  local home state backup buf
  home=$(make_home away-reclaim-buffer-no-mix)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  printf 'live buffer\n' > "$buf"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'stale backup buffer\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"
  printf 'wedged\n' > "$backup/.subsuper-inject-wedged"

  away_ledger_reclaim_backups "$state" "$buf" "$state/.subsuper-inject-wedged" \
    "$state/.afk-launch-backup.*" \
    && fail "reclaim must report failure when a live buffer conflicts with a backup's group"

  [ "$(cat "$buf" 2>/dev/null)" = 'live buffer' ] \
    || fail "reclaim must never overwrite an existing live escalation buffer"
  [ ! -e "${buf}.since" ] \
    || fail "reclaim must never pair a live buffer with a foreign backup sidecar"
  [ ! -e "$state/.subsuper-inject-wedged" ] \
    || fail "reclaim must never adopt a foreign wedge marker while a live buffer exists"
  [ -f "$backup/.subsuper-escalations" ] && [ -f "$backup/.subsuper-escalations.since" ] \
    || fail "reclaim must keep the backup's buffer and sidecar intact for a later reclaim"
  pass "reclaim never mixes a live buffer with a foreign backup's sidecar or wedge marker"
}

# The exact reachable sequence the mixing bug came from: escalate_add's
# fail-closed path can retire the sidecar while still appending the line,
# leaving a live buffer with NO sidecar at all. An orphaned backup's sidecar
# must still never be paired onto that live buffer merely because the live
# sidecar happens to be absent - the live buffer's mere presence is what rules
# out adoption, independent of whether its own sidecar exists.
test_away_reclaim_backups_never_pairs_orphan_sidecar_with_sidecarless_live_buffer() {
  local home state backup buf
  home=$(make_home away-reclaim-sidecarless-live)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  printf 'live: escalation with no sidecar yet\n' > "$buf"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'blocked: unrelated orphaned batch\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 1 2 0 0 none\n' > "$backup/.subsuper-escalations.since"

  away_ledger_reclaim_backups "$state" "$buf" "$state/.subsuper-inject-wedged" \
    "$state/.afk-launch-backup.*" \
    && fail "reclaim must report failure rather than adopt a foreign sidecar"

  [ ! -e "${buf}.since" ] \
    || fail "an orphaned sidecar must never attach to a live buffer it does not describe"
  [ "$(cat "$buf" 2>/dev/null)" = 'live: escalation with no sidecar yet' ] \
    || fail "the live buffer's own escalation line must survive untouched"
  [ -f "$backup/.subsuper-escalations.since" ] \
    || fail "the orphaned backup's sidecar must be preserved for a later reclaim"
  pass "reclaim never pairs an orphaned sidecar with a live buffer, sidecar-less or not"
}

# A copy failure partway through a backup's reconciliation must never destroy
# the backup: the whole point of retaining it is recovery, so a merge that
# cannot fully complete must leave the complete backup in place for the next
# reclaim attempt rather than deleting it once some (but not all) of its
# artifacts were folded in.
test_away_reclaim_backups_keeps_backup_on_partial_merge_failure() {
  local home state backup live
  home=$(make_home away-reclaim-partial-failure)
  state="$home/state"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  mkdir -p "$backup/tg-away-digest"
  printf 'blocked: first item\n' > "$backup/tg-away-digest/1700000000-abc-a0-0-x.items"
  printf 'blocked: second item\n' > "$backup/tg-away-digest/1700000000-abc-a0-1-y.items"

  (
    cp() {
      case "$2" in
        *1700000000-abc-a0-1-y.items) return 1 ;;
        *) command cp "$@" ;;
      esac
    }
    away_ledger_reclaim_backups "$state" "$state/.subsuper-escalations" \
      "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*"
  ) && fail "reclaim must report failure when any artifact fails to merge"

  live="$state/tg-away-digest/1700000000-abc-a0-0-x.items"
  [ -f "$live" ] \
    || fail "reclaim must still merge the items that copied successfully"
  [ -d "$backup" ] \
    || fail "reclaim must keep the whole backup when any of its artifacts failed to merge"
  [ -f "$backup/tg-away-digest/1700000000-abc-a0-1-y.items" ] \
    || fail "the backup's unmerged item must survive for the next reclaim attempt"
  pass "reclaim keeps the complete backup when only part of it could be merged"
}

# The return status must distinguish an ordinary wait state (a live buffer
# conflicts with a backup's group - expected during an active away session)
# from a real fault, so a caller can log the latter without alarming on the
# former on every routine launch/refresh during a live session.
test_away_reclaim_backups_returns_deferred_not_failure_on_live_conflict() {
  local home state backup rc
  home=$(make_home away-reclaim-rc-deferred)
  state="$home/state"
  printf 'live buffer\n' > "$state/.subsuper-escalations"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'stale backup buffer\n' > "$backup/.subsuper-escalations"

  rc=0
  away_ledger_reclaim_backups "$state" "$state/.subsuper-escalations" \
    "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*" || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "a live-conflict-only outcome must return the deferred status 2 (got: $rc)"
  pass "reclaim returns the deferred status, not a failure, on a mere live conflict"
}

test_away_reclaim_backups_returns_zero_when_nothing_to_reclaim() {
  local home state rc
  home=$(make_home away-reclaim-rc-clean)
  state="$home/state"
  rc=0
  away_ledger_reclaim_backups "$state" "$state/.subsuper-escalations" \
    "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "reclaim must return 0 when no backup matches the glob (got: $rc)"
  pass "reclaim returns 0 when there is nothing to reclaim"
}

test_away_reclaim_backups_returns_failure_on_real_copy_error() {
  local home state backup rc
  home=$(make_home away-reclaim-rc-failure)
  state="$home/state"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  mkdir -p "$backup/tg-away-digest"
  printf 'blocked: item\n' > "$backup/tg-away-digest/1700000000-abc-a0-0-x.items"

  rc=0
  (
    cp() { return 1; }
    away_ledger_reclaim_backups "$state" "$state/.subsuper-escalations" \
      "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*"
  ) || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a real copy failure must return status 1, distinct from the deferred status (got: $rc)"
  pass "reclaim returns the failure status, not deferred, on a real copy error"
}

# Adopting a backup's buffer/sidecar/wedge group is only safe when nothing
# else can be writing those live paths. A live daemon is the sole writer of
# the buffer and its sidecar with no shared lock, so digests-only mode must
# defer the whole group - never adopting it, never even reporting it as a
# real failure - while still merging digest text, which is always safe.
test_away_reclaim_backups_digests_only_defers_the_group() {
  local home state backup buf rc
  home=$(make_home away-reclaim-digests-only)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'blocked: must not be adopted while a daemon owns this path\n' \
    > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"
  mkdir -p "$backup/tg-away-digest"
  printf 'blocked: safe to merge regardless\n' \
    > "$backup/tg-away-digest/1700000000-abc-a0-0-x.items"

  rc=0
  away_ledger_reclaim_backups "$state" "$buf" "$state/.subsuper-inject-wedged" \
    "$state/.afk-launch-backup.*" 1 || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "digests-only mode must report a deferred group as status 2, not a failure (got: $rc)"
  [ ! -e "$buf" ] \
    || fail "digests-only mode must never adopt the buffer while a daemon could own it"
  [ -f "$backup/.subsuper-escalations" ] \
    || fail "digests-only mode must leave the backup's buffer copy untouched"
  [ -f "$state/tg-away-digest/1700000000-abc-a0-0-x.items" ] \
    || fail "digests-only mode must still merge digest text, which is always safe"
  pass "digests-only mode defers group adoption without treating it as a failure"
}

# Group adoption writes each artifact through the same same-directory
# mktemp-then-mv pattern the ledger's own sidecar writer uses, so a reader can
# never observe a half-copied file. Simulate a mid-group failure (the sidecar
# copy fails after the buffer already landed) and confirm the live buffer is
# never left holding a value with no matching sidecar copy attempt - the
# failure must be reported, and the backup must retain what was not adopted.
test_away_reclaim_backups_group_adoption_is_atomic_per_file() {
  local home state backup buf rc
  home=$(make_home away-reclaim-atomic-group)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'blocked: adopted buffer line\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"

  rc=0
  (
    cp() {
      case "$2" in
        (*.subsuper-escalations.since) return 1 ;;
        (*) command cp "$@" ;;
      esac
    }
    away_ledger_reclaim_backups "$state" "$buf" "$state/.subsuper-inject-wedged" \
      "$state/.afk-launch-backup.*"
  ) || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a mid-group copy failure must report status 1 (got: $rc)"
  [ -d "$backup" ] \
    || fail "the backup must survive a mid-group adoption failure"
  [ ! -e "${buf}.since" ] \
    || fail "a failed sidecar copy must never leave a partial file at the live path"
  [ ! -e "$buf" ] \
    || fail "a failed later artifact must roll back an already-committed earlier one, never leaving a sidecar-less live buffer"
  [ -f "$backup/.subsuper-escalations" ] \
    || fail "the rolled-back buffer must remain in the backup as the single complete copy"
  [ -f "$backup/.subsuper-escalations.since" ] \
    || fail "the backup's sidecar must remain intact after a rolled-back adoption"
  pass "group adoption writes atomically and rolls back a partial group without a partial live write"
}

# The rollback list must be quoted correctly for a live buffer/sidecar path
# containing a space - an unquoted, word-split rollback would silently no-op
# on such a path and leave an already-committed live buffer with no sidecar,
# exactly the partial state the atomic rollback exists to prevent. The backup
# itself lives under a separate, space-free directory here so the test
# isolates the rollback's own path handling from the unrelated, pre-existing
# word-splitting in the backup-glob loop.
test_away_reclaim_backups_group_rollback_survives_a_path_with_a_space() {
  local live glob_dir backup buf rc
  live=$(mktemp -d "${TMPDIR:-/tmp}/fm tg live.XXXXXX")
  glob_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-tg-glob.XXXXXX")
  buf="$live/.subsuper-escalations"
  backup=$(mktemp -d "$glob_dir/.afk-launch-backup.XXXXXX")
  printf 'blocked: adopted buffer line\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"

  rc=0
  (
    cp() {
      case "$2" in
        (*.subsuper-escalations.since) return 1 ;;
        (*) command cp "$@" ;;
      esac
    }
    away_ledger_reclaim_backups "$live" "$buf" "$live/.subsuper-inject-wedged" \
      "$glob_dir/.afk-launch-backup.*"
  ) || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a mid-group copy failure with a space-containing live path must report status 1 (got: $rc)"
  [ ! -e "$buf" ] \
    || fail "rollback must remove an already-committed buffer even when its path contains a space"
  [ -f "$backup/.subsuper-escalations" ] \
    || fail "the rolled-back buffer must remain in the backup under a space-containing live path"
  rm -rf "$live" "$glob_dir"
  pass "group adoption rollback correctly quotes a live path containing a space"
}

# A `.consumed` marker left by an interrupted away_ledger_fold_retained_backups
# removal must never be treated as an ordinary unreconciled backup by reclaim -
# it already had its evidence published, so reclaim must only retry removing
# it, never adopt or merge from it, which would publish the same content twice.
test_away_reclaim_backups_never_adopts_a_consumed_marker() {
  local home state backup consumed buf rc
  home=$(make_home away-reclaim-consumed-marker)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'blocked: already published by an earlier fold\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"
  consumed="${backup}.consumed"
  mv "$backup" "$consumed"

  rc=0
  away_ledger_reclaim_backups "$state" "$buf" "$state/.subsuper-inject-wedged" \
    "$state/.afk-launch-backup.*" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "reclaim must succeed once a consumed marker's removal is no longer blocked (got: $rc)"
  [ ! -e "$buf" ] \
    || fail "reclaim must never adopt a consumed marker's buffer - its evidence was already published"
  assert_absent "$consumed" "reclaim must remove a consumed marker once recovery succeeds"
  pass "reclaim never adopts from a consumed marker, only retries its removal"
}

# Reclaim's own staging temp files must fall inside the cleanup sweep that
# retires an away session's working records, so a crash between mktemp and mv
# can never leak a private copy of escalation text into the state directory
# permanently.
test_away_reclaim_backups_staging_temp_falls_inside_the_cleanup_sweep() {
  local home state
  home=$(make_home away-reclaim-temp-sweep)
  state="$home/state"
  : > "$state/.subsuper-escalations.reclaim.XXXXXX"
  : > "$state/.subsuper-escalations.since.reclaim.XXXXXX"
  : > "$state/.subsuper-inject-wedged.reclaim.XXXXXX"

  away_ledger_retire_working_records "$state"

  assert_absent "$state/.subsuper-escalations.reclaim.XXXXXX" \
    "a leaked buffer staging temp must be swept by working-records retirement"
  assert_absent "$state/.subsuper-escalations.since.reclaim.XXXXXX" \
    "a leaked sidecar staging temp must be swept by working-records retirement"
  assert_absent "$state/.subsuper-inject-wedged.reclaim.XXXXXX" \
    "a leaked wedge staging temp must be swept by working-records retirement"
  pass "reclaim's staging temps fall inside the working-records cleanup sweep"
}

# away_ledger_fold_retained_backups must surface exactly the lines a retained
# backup's own sidecar says are still undigested - never anything already
# accounted for, which would duplicate content already delivered to Telegram -
# and must remove the backup once folded, so it cannot resurface again.
test_away_fold_retained_backups_folds_only_undigested_lines() {
  local home state backup buf out
  home=$(make_home away-fold-retained)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  printf 'live buffer\n' > "$buf"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'already digested\nstill undigested\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 2 2 1 0 0 none\n' > "$backup/.subsuper-escalations.since"

  out=$(away_ledger_fold_retained_backups "$state" "$buf" \
    "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*") \
    || fail "fold_retained_backups must succeed"

  assert_grep 'still undigested' <(printf '%s\n' "$out") \
    "the undigested line must be folded into the returned evidence"
  assert_no_grep 'already digested' <(printf '%s\n' "$out") \
    "an already-digested line must never be folded again"
  assert_absent "$backup" "the backup must be removed once its content is folded"
  pass "fold_retained_backups folds only the lines past the backup's own accounted count"
}

test_away_fold_retained_backups_folds_wedge_evidence() {
  local home state backup out
  home=$(make_home away-fold-retained-wedge)
  state="$home/state"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'stranded wedge alarm\n' > "$backup/.subsuper-inject-wedged"

  out=$(away_ledger_fold_retained_backups "$state" "$state/.subsuper-escalations" \
    "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*") \
    || fail "fold_retained_backups must succeed"

  assert_grep 'stranded wedge alarm' <(printf '%s\n' "$out") \
    "a retained backup's wedge marker must be folded into the returned evidence"
  assert_absent "$backup" "the backup must be removed once its wedge is folded"
  pass "fold_retained_backups folds a retained backup's wedge marker"
}

# Publication and removal are atomic: if a backup's digest item cannot be
# merged, fold_retained_backups must neither print that backup's buffer/wedge
# evidence nor remove it, so a later retry - once the fault clears - is the
# only place that content is ever emitted, never duplicated across two calls.
test_away_fold_retained_backups_never_publishes_on_digest_merge_failure() {
  local home state backup buf out rc
  home=$(make_home away-fold-retained-digest-failure)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'blocked: still undigested\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"
  printf 'stranded wedge alarm\n' > "$backup/.subsuper-inject-wedged"
  mkdir -p "$backup/tg-away-digest"
  printf 'blocked: undeliverable digest\n' > "$backup/tg-away-digest/1700000000-abc-a0-0-x.items"

  rc=0
  out=$(
    cp() {
      case "$2" in
        (*tg-away-digest*) return 1 ;;
        (*) command cp "$@" ;;
      esac
    }
    away_ledger_fold_retained_backups "$state" "$buf" \
      "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*"
  ) || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "fold_retained_backups must report failure when a digest item cannot be merged"
  [ -z "$out" ] \
    || fail "no evidence may be emitted for a backup that was not fully reconciled and removed"
  [ -d "$backup" ] \
    || fail "the backup must survive a digest-merge failure for a later retry"
  [ -f "$backup/.subsuper-escalations" ] \
    || fail "the backup's buffer must remain intact alongside its unmerged digest"
  assert_absent "$state/tg-away-digest/1700000000-abc-a0-0-x.items" \
    "a failed merge must never leave a partial copy in the live digest directory"
  pass "fold_retained_backups never publishes or removes a backup on a digest-merge failure"
}

# The commit point is the rename to a `.consumed` marker, not the final `rm
# -rf` - so a removal failure AFTER that rename must never re-emit the
# already-published evidence on a later call, and a later call must simply
# retry removing the marker until it succeeds.
test_away_fold_retained_backups_recovers_a_consumed_marker_without_republishing() {
  local home state backup consumed out rc
  home=$(make_home away-fold-retained-consumed-marker)
  state="$home/state"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'blocked: already published once\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"
  consumed="${backup}.consumed"
  mv "$backup" "$consumed"

  rc=0
  out=$(away_ledger_fold_retained_backups "$state" "$state/.subsuper-escalations" \
    "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*") || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "recovering a consumed marker must succeed once its removal is no longer blocked"
  [ -z "$out" ] \
    || fail "a consumed marker must never re-emit evidence already published in an earlier call"
  assert_absent "$consumed" "a consumed marker must be removed once recovery succeeds"
  pass "fold_retained_backups recovers a leftover consumed marker without republishing its evidence"
}

# A digest-merge failure inside a backup must never leave an already-adopted
# buffer/sidecar/wedge group sitting in that backup for a later
# away_ledger_fold_retained_backups pass to fold a second time - the group is
# consumed from the backup the moment it is adopted, independent of whatever
# happens to that backup's unrelated digest items.
test_away_reclaim_backups_group_adoption_survives_a_sibling_digest_failure() {
  local home state backup buf out live_digest rc
  home=$(make_home away-reclaim-group-vs-digest-failure)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  printf 'blocked: adopted line\n' > "$backup/.subsuper-escalations"
  printf '1700000000-abc 1 0 0 0 0 none\n' > "$backup/.subsuper-escalations.since"
  mkdir -p "$backup/tg-away-digest"
  printf 'blocked: undeliverable digest\n' > "$backup/tg-away-digest/1700000000-abc-a0-0-x.items"

  (
    cp() {
      case "$2" in
        *tg-away-digest*) return 1 ;;
        *) command cp "$@" ;;
      esac
    }
    away_ledger_reclaim_backups "$state" "$buf" "$state/.subsuper-inject-wedged" \
      "$state/.afk-launch-backup.*"
  ) && fail "reclaim must report failure when the digest merge fails"

  [ "$(cat "$buf" 2>/dev/null)" = 'blocked: adopted line' ] \
    || fail "the group must still be adopted despite the sibling digest failure"
  [ -d "$backup" ] \
    || fail "the backup must survive so its unmerged digest can be retried"
  [ ! -e "$backup/.subsuper-escalations" ] \
    || fail "an adopted group must be consumed from the backup immediately"
  [ -f "$backup/tg-away-digest/1700000000-abc-a0-0-x.items" ] \
    || fail "reclaim must never destroy a digest item it failed to merge"

  live_digest="$state/tg-away-digest/1700000000-abc-a0-0-x.items"
  assert_absent "$live_digest" \
    "the failed digest merge must not have reached the live digest directory"

  rc=0
  out=$(away_ledger_fold_retained_backups "$state" "$buf" \
    "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*") || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "fold_retained_backups must succeed once the digest client is no longer failing"
  assert_no_grep 'adopted line' <(printf '%s\n' "$out") \
    "a group already adopted must never be folded again by fold_retained_backups"
  [ -f "$live_digest" ] \
    || fail "fold_retained_backups must fold the previously unmerged digest item"
  [ "$(cat "$live_digest" 2>/dev/null)" = 'blocked: undeliverable digest' ] \
    || fail "the folded digest item's content must survive intact"
  [ "$(find "$state/tg-away-digest" -name '1700000000-abc-a0-0-x.items' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the digest item must exist exactly once after folding"
  assert_absent "$backup" \
    "the backup must be removed once its digest item is folded and merged"
  pass "an adopted group is consumed immediately, and a sibling digest failure is folded exactly once once resolved"
}

# A live delivery id's digest file must never be clobbered by a reclaim: if the
# same delivery id somehow exists in both the live directory and an orphaned
# backup, the live copy - already possibly folded or read - wins.
test_away_reclaim_backups_never_overwrites_a_live_digest() {
  local home state backup
  home=$(make_home away-reclaim-no-clobber)
  state="$home/state"
  (umask 077; mkdir -p "$state/tg-away-digest")
  printf 'live copy\n' > "$state/tg-away-digest/1700000000-abc-a0-0-x.items"
  backup=$(mktemp -d "$state/.afk-launch-backup.XXXXXX")
  mkdir -p "$backup/tg-away-digest"
  printf 'stale backup copy\n' > "$backup/tg-away-digest/1700000000-abc-a0-0-x.items"

  away_ledger_reclaim_backups "$state" "$state/.subsuper-escalations" \
    "$state/.subsuper-inject-wedged" "$state/.afk-launch-backup.*" \
    || fail "reclaim must succeed"

  [ "$(cat "$state/tg-away-digest/1700000000-abc-a0-0-x.items" 2>/dev/null)" = 'live copy' ] \
    || fail "reclaim must never overwrite an existing live digest file"
  assert_absent "$backup" "reclaim must still remove the orphaned backup"
  pass "reclaim never overwrites a live digest file with an orphaned backup's copy"
}

# An uncertain outcome poisons the batch for the phone: confirmation can only ever
# extend a contiguous proven prefix, so a later line is never sent (which would
# risk a duplicate of the uncertain one) and never presented as delivered.
test_away_uncertain_send_stops_the_batch_from_reaching_the_phone() {
  local home state tg injected
  home=$(make_home away-uncertain-gap)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"

  escalate_add "$state" 'blocked: first event, response lost'
  (
    inject_msg() { return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" FAKE_TG_EXIT=1 escalate_flush "$state"
  ) && fail "a wedged receipt must leave escalate_flush unconfirmed"
  [ "$(grep -c '^---$' "$home/tg-sent.log")" -eq 1 ] \
    || fail "the first event must have been attempted exactly once"
  ledger_field "$state" 3 0 "an uncertain send must not confirm anything"

  escalate_add "$state" 'blocked: second event after the uncertainty'
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "an uncertain batch must still complete the in-session flush"

  [ "$(grep -c '^---$' "$home/tg-sent.log")" -eq 1 ] \
    || fail "no event may reach the phone after an uncertain send in the same batch"
  assert_grep 'Telegram delivery uncertain' "$injected" \
    "an uncertain batch must never be reported as accepted"
  assert_grep 'first event, response lost' "$injected" \
    "the uncertain event must reach the visible in-session fallback"
  assert_grep 'second event after the uncertainty' "$injected" \
    "the later event must reach the visible in-session fallback"
  assert_no_grep 'accepted away-mode alert' "$injected" \
    "an unproven line must never be presented as delivered"
  pass "an uncertain send keeps its reservation and stops the batch reaching the phone"
}

# A client that actually ran and exited 125 (or 124) must never be treated as
# proven-local: those exit codes belong exclusively to wedge_alarm_run_bounded's
# own pre-launch guard and timeout. A client-produced 125 must stay ambiguous -
# reservation kept, attempt ordinal unchanged - so the same lines are never
# offered to the phone again under a fresh delivery id (which would duplicate
# the captain alert the client may already have sent).
test_away_client_exit_125_is_never_proven_local() {
  local home state tg injected
  home=$(make_home away-client-exit-125)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"
  escalate_add "$state" 'blocked: client exited 125 after issuing the request'

  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" FAKE_TG_EXIT=125 escalate_flush "$state"
  ) && fail "a client exit 125 must leave escalate_flush unconfirmed"
  [ "$(grep -c '^---$' "$home/tg-sent.log")" -eq 1 ] \
    || fail "the client must have been invoked exactly once"
  ledger_field "$state" 2 1 "a client exit 125 must keep its reservation"
  ledger_field "$state" 3 0 "a client exit 125 must not confirm anything"
  ledger_field "$state" 5 0 "a client exit 125 must not advance the attempt ordinal"
  assert_grep 'Telegram delivery uncertain' "$injected" \
    "a client exit 125 must never be reported as a proven-local failure"

  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "a poisoned batch must still complete the in-session flush"
  [ "$(grep -c '^---$' "$home/tg-sent.log")" -eq 1 ] \
    || fail "an ambiguous exit 125 must never be retried, which would risk a duplicate phone alert"
  pass "a client exit 125 stays ambiguous and is never retried as proven-local"
}

# Every send must come through the ledger: no default arguments, no id minted
# outside the owner, no bypass of the exactly-once accounting.
test_away_delivery_refuses_untracked_sends() {
  local home state tg out
  home=$(make_home away-untracked)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  escalate_add "$state" 'blocked: needs the ledger'

  out=$(
    export FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live
    export FMTG_TG_BIN="$tg"
    telegram_away_deliver "$state" 'blocked: needs the ledger'
  )
  [ "$out" = 'unavailable|none' ] \
    || fail "a send without ledger arguments must refuse (got: $out)"

  out=$(
    export FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live
    export FMTG_TG_BIN="$tg"
    telegram_away_deliver "$state" 'blocked: needs the ledger' 0 1 0 not-this-batch
  )
  [ "$out" = 'unavailable|none' ] \
    || fail "a send naming another batch must refuse (got: $out)"

  rm -f "$state/.subsuper-escalations.since"
  out=$(
    export FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live
    export FMTG_TG_BIN="$tg"
    telegram_away_deliver "$state" 'blocked: needs the ledger' 0 1 0 1700000000-abcdef0123456789
  )
  [ "$out" = 'unavailable|none' ] \
    || fail "a send with no readable ledger must refuse (got: $out)"

  assert_absent "$home/tg-sent.log" "an untracked send must never reach the phone"
  assert_absent "$state/tg-away-delivery" "an untracked send must not mint delivery evidence"
  pass "away delivery refuses every send that does not come through the ledger"
}

# A failure that provably never left the box must be genuinely retryable: the
# retired attempt keeps its evidence, the ordinal advances, and the very same lines
# reach the phone on the next flush once the client is back.
test_away_proven_local_failure_retries_the_same_lines() {
  local home state tg injected first_evidence ledger
  home=$(make_home away-proven-local-retry)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"
  escalate_add "$state" 'blocked: needs the captain, client offline'

  # The client is not runnable yet, and the in-session receipt is wedged too, so
  # the batch survives with its ledger.
  (
    inject_msg() { return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FM_TG_AWAY_RETRY_SECS=3600 FMTG_TG_BIN="$home/missing-tg" escalate_flush "$state"
  ) && fail "a wedged receipt must leave escalate_flush unconfirmed"
  assert_absent "$home/tg-sent.log" "a missing client cannot have sent anything"
  ledger_field "$state" 2 0 "a proven-local failure must release its reservation"
  ledger_field "$state" 5 1 "a proven-local failure must retire its attempt"
  first_evidence=$(ls "$state/tg-away-delivery"/*.status | head -n 1)
  grep -Eq '^unavailable [0-9]+ sender_missing$' "$first_evidence" \
    || fail "the retired attempt must keep its durable evidence"

  # The retry is scheduled, not immediate: while the backoff is unelapsed the flush
  # neither contacts the phone nor mints another evidence record.
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FM_TG_AWAY_RETRY_SECS=3600 FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) && fail "the still-wedged receipt must leave escalate_flush unconfirmed"
  assert_absent "$home/tg-sent.log" "a deferred retry must not contact the phone"
  assert_grep 'Telegram delivery deferred' "$injected" \
    "a deferred retry must say so in the in-session fallback"
  [ "$(ls "$state/tg-away-delivery"/*.status | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "a deferred retry must not mint another evidence record per tick"
  ledger_field "$state" 5 1 "a deferred retry must not advance the attempt ordinal"

  # The client comes back and the schedule elapses. The same buffer, unchanged,
  # must now reach the phone.
  ledger=$(away_ledger_read "$state/.subsuper-escalations")
  # shellcheck disable=SC2086
  set -- $ledger
  away_ledger_write "$state/.subsuper-escalations" "$1" "$2" "$3" "$4" "$5" 0 "$7" \
    || fail "could not elapse the retry schedule"
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "the retry must complete the away flush"
  assert_grep 'needs the captain, client offline' "$home/tg-sent.log" \
    "a released attempt must be able to reach the phone again"
  [ "$(grep -c '^---$' "$home/tg-sent.log")" -eq 1 ] \
    || fail "the retry must contact the phone exactly once"
  assert_grep 'Telegram accepted away-mode alert' "$injected" \
    "the successful retry must report its real accepted outcome"
  [ -f "$first_evidence" ] \
    || fail "the retried attempt must not erase the earlier attempt's evidence"
  pass "a proven-local failure retires its attempt and retries the same lines"
}

# The counts are validated one by one before any comparison, sender call, or ledger
# mutation, so a partially-empty argument list cannot mint an id or send.
test_away_delivery_refuses_malformed_counts() {
  local home state batch_id tg
  home=$(make_home away-malformed-counts)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  escalate_add "$state" 'blocked: must not slip through'
  batch_id=$(away_ledger_read "$state/.subsuper-escalations" | cut -d' ' -f1)

  malformed_refused() {  # <label> <offset> <total> <accounted>
    local label=$1 out
    out=$(
      export FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live
      export FMTG_TG_BIN="$tg"
      telegram_away_deliver "$state" 'blocked: must not slip through' \
        "$2" "$3" "$4" "$batch_id" 2>&1
    )
    [ "$out" = 'unavailable|none' ] \
      || fail "$label must refuse before anything else (got: $out)"
  }
  malformed_refused 'an empty offset' '' 1 0
  malformed_refused 'an empty total' 0 '' 0
  malformed_refused 'an empty accounted' 0 1 ''
  malformed_refused 'a non-numeric offset' x 1 0
  malformed_refused 'a non-numeric total' 0 y 0
  malformed_refused 'a non-numeric accounted' 0 1 z
  malformed_refused 'a negative offset' -1 1 0

  assert_absent "$home/tg-sent.log" "a malformed call must never reach the phone"
  assert_absent "$state/tg-away-delivery" "a malformed call must not mint delivery evidence"
  ledger_field "$state" 2 0 "a malformed call must not mutate the ledger"
  ledger_field "$state" 5 0 "a malformed call must not retire an attempt"
  pass "away delivery refuses malformed counts before any send or ledger write"
}

# A ledger write that fails before any attempt must not tombstone the delivery id:
# nothing was reserved and nothing was sent, so the next flush has to be able to
# retry cleanly once the state directory is writable again.
test_away_unwritable_ledger_leaves_the_id_retryable() {
  local home state tg injected
  home=$(make_home away-unwritable-ledger)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"
  escalate_add "$state" 'blocked: state dir full'

  # A read-only state dir makes the sidecar mktemp/mv fail, so the reservation
  # cannot be recorded.
  chmod 0500 "$state"
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) && fail "an unwritable ledger must leave escalate_flush unconfirmed"
  chmod 0755 "$state"

  assert_absent "$home/tg-sent.log" "an unreserved attempt must never reach the phone"
  assert_grep 'blocked: state dir full' "$injected" \
    "the unsent event must reach the visible in-session fallback"
  if [ -d "$state/tg-away-delivery" ] && ls "$state/tg-away-delivery"/*.status >/dev/null 2>&1; then
    fail "no attempt was made, so no delivery evidence may tombstone that id"
  fi

  # Writable again: the same lines must now reach the phone.
  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 0; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) || fail "the retry after a writable ledger must complete the away flush"
  assert_grep 'state dir full' "$home/tg-sent.log" \
    "an unreserved attempt must stay retryable once the ledger is writable"
  pass "an unwritable ledger never tombstones an id that made no attempt"
}

# An in-place daemon upgrade during a live away session must migrate the older
# ledger shapes instead of failing closed and repeating delivered lines in chat.
test_away_ledger_migrates_older_record_shapes() {
  local home state buf rec
  home=$(make_home away-ledger-migration)
  state="$home/state"
  buf="$state/.subsuper-escalations"
  printf 'blocked: one\nblocked: two\n' > "$buf"

  # Round-5 shape: id reserved confirmed accounted delivery-id.
  printf '1700000050-abcdef0123456789 1 1 1 1700000050-abcdef0123456789-0-aaaaaaaaaaaaaaaa\n' \
    > "$buf.since"
  rec=$(away_ledger_read "$buf")
  [ "$rec" != unknown ] || fail "the five-field ledger must migrate, not fail closed"
  [ "$rec" = '1700000050-abcdef0123456789 1 1 1 0 0 1700000050-abcdef0123456789-0-aaaaaaaaaaaaaaaa' ] \
    || fail "the five-field ledger must keep its counts and default the new fields (got: $rec)"
  [ "$(away_ledger_read "$buf")" = "$rec" ] \
    || fail "the migrated ledger must persist in place"

  # Round-6 shape: ... attempt delivery-id.
  printf '1700000060-abcdef0123456789 2 2 2 3 1700000060-abcdef0123456789-a3-0-bbbbbbbbbbbbbbbb\n' \
    > "$buf.since"
  rec=$(away_ledger_read "$buf")
  [ "$rec" = '1700000060-abcdef0123456789 2 2 2 3 0 1700000060-abcdef0123456789-a3-0-bbbbbbbbbbbbbbbb' ] \
    || fail "the six-field ledger must keep its attempt ordinal (got: $rec)"

  # A genuinely malformed record still fails closed.
  printf '1700000070-abcdef0123456789 2 2\n' > "$buf.since"
  [ "$(away_ledger_read "$buf")" = unknown ] \
    || fail "a malformed ledger must still fail closed"
  pass "the ledger owner migrates older record shapes in place and still fails closed"
}

# The retry schedule must stay armed even in the documented immediate-batching
# mode, where housekeeping flushes on every tick: a non-positive delay would spin
# the whole reserve/attempt/spool/release cycle and mint an evidence file per tick.
test_away_retry_throttle_survives_immediate_batching() {
  local home state tg injected retry_after evidence_count
  home=$(make_home away-retry-throttle)
  state="$home/state"
  tg=$(make_fake_tg "$home")
  : > "$state/.afk"
  injected="$home/injected.log"
  escalate_add "$state" 'blocked: client offline under immediate batching'

  (
    inject_msg() { return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FM_ESCALATE_BATCH_SECS=0 FM_TG_AWAY_RETRY_SECS=0 \
      FMTG_TG_BIN="$home/missing-tg" escalate_flush "$state"
  ) && fail "a wedged receipt must leave escalate_flush unconfirmed"

  retry_after=$(away_ledger_read "$state/.subsuper-escalations" | cut -d' ' -f6)
  [ "$retry_after" -gt 0 ] \
    || fail "a retired proven-local attempt must arm a positive retry schedule (got: $retry_after)"
  evidence_count=$(ls "$state/tg-away-delivery"/*.status | wc -l | tr -d ' ')

  (
    inject_msg() { printf '%s\n' "$1" > "$injected"; return 1; }
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_TG_AWAY_EXEC=live \
      FM_ESCALATE_BATCH_SECS=0 FM_TG_AWAY_RETRY_SECS=0 \
      FMTG_TG_BIN="$tg" escalate_flush "$state"
  ) && fail "the still-wedged receipt must leave escalate_flush unconfirmed"

  assert_grep 'Telegram delivery deferred' "$injected" \
    "an armed retry schedule must defer the next tick's attempt"
  assert_absent "$home/tg-sent.log" "a deferred tick must not contact the phone"
  [ "$(ls "$state/tg-away-delivery"/*.status | wc -l | tr -d ' ')" -eq "$evidence_count" ] \
    || fail "a deferred tick must not mint another evidence record"
  pass "the proven-local retry schedule stays bounded under immediate batching"
}

test_supervision_instructions_carry_tg_cadence() {
  local home out
  home="$TMP_ROOT/sup-instructions"; mkdir -p "$home/config"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/tg-mode.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude 2>/dev/null)
  assert_contains "$out" "Telegram mode: active; source $home/config/tg-mode.env" \
    "the operating block must name the Telegram cadence file"
  # X mode being off must not contradict the Telegram 30s cadence one line down.
  assert_not_contains "$out" "default watcher cadence" \
    "an inactive X mode must not claim the default cadence while Telegram mode is active"
  assert_not_contains "$out" "Watcher cadence: default" \
    "the block must not claim the default cadence while Telegram mode is active"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line 2>/dev/null)
  assert_contains "$out" "source '$home/config/tg-mode.env' first" \
    "the repair line must source the Telegram cadence file"
  # Without the file the current-state block does not claim the mode is active.
  rm "$home/config/tg-mode.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude 2>/dev/null)
  assert_not_contains "$out" "- Telegram mode: active" \
    "a non-opted-in home must not report Telegram mode active"
  assert_contains "$out" "- Telegram mode: inactive." \
    "the block must report Telegram mode inactive symmetrically with X mode"
  assert_contains "$out" "Watcher cadence: default" \
    "with both modes off the block must state the default cadence once"
  pass "supervision instructions carry the Telegram cadence exactly when armed"
}

test_poll_no_optin_is_hard_noop
test_poll_emits_ids_only_never_note_text
test_poll_multiple_ids_one_line
test_poll_offers_once_then_silent
test_poll_reoffers_stale_unclaimed_note
test_poll_prunes_markers_for_gone_notes
test_poll_missing_inbox_reports_once
test_poll_ignores_malformed_filenames
test_shim_validation_accepts_only_exact_private_identity
test_bootstrap_inert_without_optin
test_bootstrap_activates_on_optin_flag
test_bootstrap_opt_out_cleanup
test_bootstrap_does_not_follow_tg_artifact_symlinks
test_migration_preserves_valid_tg_shim
test_migration_neutralizes_tampered_tg_shim
test_watcher_dispatches_valid_tg_shim_end_to_end
test_watcher_rejects_tampered_tg_shim
test_link_records_note_and_timestamp
test_link_rejects_unsafe_and_missing
test_followup_lifecycle
test_away_delivery_is_inert_outside_away_mode
test_away_delivery_is_accepted_once_and_records_no_content
test_away_delivery_failure_classes_and_safe_chat_fallback
test_away_delivery_acceptance_does_not_duplicate_alert_in_chat
test_away_batch_never_resends_accepted_events
test_away_unusable_bookkeeping_never_sends_to_the_phone
test_away_reserved_lines_resolve_from_evidence_not_from_the_claim
test_away_off_mid_batch_never_repeats_delivered_events
test_away_lifecycle_retires_tg_working_records
test_away_reclaim_backups_folds_orphaned_digest_text
test_away_reclaim_backups_never_overwrites_a_live_digest
test_away_reclaim_backups_fills_missing_buffer_and_sidecar
test_away_reclaim_backups_never_mixes_a_live_buffer_with_a_foreign_group
test_away_reclaim_backups_never_pairs_orphan_sidecar_with_sidecarless_live_buffer
test_away_reclaim_backups_keeps_backup_on_partial_merge_failure
test_away_reclaim_backups_returns_deferred_not_failure_on_live_conflict
test_away_reclaim_backups_returns_zero_when_nothing_to_reclaim
test_away_reclaim_backups_returns_failure_on_real_copy_error
test_away_reclaim_backups_digests_only_defers_the_group
test_away_reclaim_backups_group_adoption_is_atomic_per_file
test_away_reclaim_backups_group_rollback_survives_a_path_with_a_space
test_away_reclaim_backups_never_adopts_a_consumed_marker
test_away_reclaim_backups_staging_temp_falls_inside_the_cleanup_sweep
test_away_fold_retained_backups_folds_only_undigested_lines
test_away_fold_retained_backups_folds_wedge_evidence
test_away_fold_retained_backups_never_publishes_on_digest_merge_failure
test_away_fold_retained_backups_recovers_a_consumed_marker_without_republishing
test_away_reclaim_backups_group_adoption_survives_a_sibling_digest_failure
test_away_uncertain_send_stops_the_batch_from_reaching_the_phone
test_away_client_exit_125_is_never_proven_local
test_away_delivery_refuses_untracked_sends
test_away_delivery_refuses_malformed_counts
test_away_proven_local_failure_retries_the_same_lines
test_away_unwritable_ledger_leaves_the_id_retryable
test_away_ledger_migrates_older_record_shapes
test_away_retry_throttle_survives_immediate_batching
test_supervision_needed_by_tg_shim
test_supervision_instructions_carry_tg_cadence

printf 'fm-tg-mode: all tests passed\n'
