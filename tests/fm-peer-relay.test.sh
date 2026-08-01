#!/usr/bin/env bash
# Carbon peer-relay regression tests: activation, exact-pane client capture,
# durable receive records, authenticated watcher-to-wake-queue dispatch, and
# reply delivery through a mocked ssh carbon transport.
set -u
set -o pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-peer-relay-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-peer-relay-tests)

make_home() {
  local home="$TMP_ROOT/$1" check body
  mkdir -p "$home/config" "$home/state"
  : > "$home/config/peer-relay-carbon"
  check="$home/state/peer-relay-watch.check.sh"
  body=$(fmpeer_poll_check_content "$home" "$ROOT")
  printf '%s\n' "$body" > "$check"
  chmod 0700 "$check"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-check-register.sh" peer-relay-watch >/dev/null \
    || fail "could not register peer-relay fixture check"
  printf '%s\n' "$home"
}

receive() {
  local home=$1 pane=${2:-%42} message=${3:-'tell firstmate the relay works'}
  printf '%s\n' \
    fm-peer-relay-v1 \
    origin_host=carbon \
    "pane_id=$pane" \
    session_name=orchestrator \
    window_id=@7 \
    client_epoch=1785600000 \
    '' \
    "$message" \
    | FM_HOME="$home" SSH_CONNECTION='100.109.135.104 5555 100.0.0.1 22' \
      FMPEER_NOW_OVERRIDE=1785600001 "$ROOT/bin/fm-peer-relay-receive.sh"
}

run_watcher_bounded() {
  local home=$1
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 FM_POLL=0.02 \
      FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "$ROOT/bin/fm-watch.sh"
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

test_bootstrap_activation_and_optout() {
  local home out
  home="$TMP_ROOT/bootstrap"
  mkdir -p "$home/config"
  : > "$home/config/peer-relay-carbon"
  FM_HOME="$home" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  assert_absent "$home/state/peer-relay-watch.check.sh" \
    "read-only bootstrap must not activate peer relay"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" 'BOOTSTRAP_INFO: carbon peer relay on' \
    "bootstrap must report completed relay activation"
  assert_present "$home/state/peer-relay-watch.check.sh" "bootstrap must create relay poll"
  assert_present "$home/state/peer-relay-watch.check-trust" "bootstrap must authenticate relay poll"
  rm "$home/config/peer-relay-carbon"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" 'BOOTSTRAP_INFO: carbon peer relay off' \
    "bootstrap must report completed relay opt-out"
  assert_absent "$home/state/peer-relay-watch.check.sh" "opt-out must remove relay poll"
  assert_absent "$home/state/peer-relay-watch.check-trust" "opt-out must remove relay trust"
  pass "bootstrap activates and removes the authenticated peer-relay poll"
}

test_receive_publishes_private_pending_record() {
  local home id dir
  home=$(make_home receive)
  id=$(receive "$home" %42 $'first line\nsecond line') \
    || fail "valid SSH receive failed"
  fmpeer_request_id_valid "$id" || fail "receiver returned an invalid request id"
  dir="$home/state/peer-relay/requests/$id"
  [ "$(path_mode "$dir")" = 700 ] || fail "request directory must be mode 0700"
  [ "$(path_mode "$dir/message")" = 600 ] || fail "request message must be mode 0600"
  assert_grep 'origin_host=carbon' "$dir/meta" "record must retain origin host"
  assert_grep 'pane_id=%42' "$dir/meta" "record must retain exact pane id"
  assert_grep 'session_name=orchestrator' "$dir/meta" "record must retain session"
  assert_grep 'window_id=@7' "$dir/meta" "record must retain stable window id"
  assert_grep 'client_epoch=1785600000' "$dir/meta" "record must retain client timestamp"
  assert_grep 'received_epoch=1785600001' "$dir/meta" "record must retain receive timestamp"
  [ "$(cat "$dir/status")" = $'state=pending\nupdated_epoch=1785600001' ] \
    || fail "new request must be pending"
  [ "$(cat "$dir/message")" = $'first line\nsecond line' ] \
    || fail "receiver changed the raw message"
  assert_absent "$home/state/.last-check" "receive must make the watcher check due"
  pass "receive atomically records private message, identity, timestamps, and pending state"
}

test_receive_rejects_nonssh_and_bad_identity() {
  local home rc
  home=$(make_home reject)
  printf '%s\n' fm-peer-relay-v1 origin_host=carbon 'pane_id=%42' \
    session_name=orchestrator window_id=@7 client_epoch=1785600000 '' message \
    | env -u SSH_CONNECTION FM_HOME="$home" "$ROOT/bin/fm-peer-relay-receive.sh" >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "non-SSH receive"
  printf '%s\n' fm-peer-relay-v1 origin_host=carbon 'pane_id=%bad1' \
    session_name=orchestrator window_id=@7 client_epoch=1785600000 '' message \
    | FM_HOME="$home" SSH_CONNECTION='x' "$ROOT/bin/fm-peer-relay-receive.sh" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "malformed pane receive"
  [ ! -d "$home/state/peer-relay/requests" ] \
    || [ -z "$(find "$home/state/peer-relay/requests" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "rejected envelopes must not publish requests"
  pass "receive rejects local callers and malformed exact-pane identities"
}

test_poll_offers_once_and_reoffers_unanswered() {
  local home id out
  home=$(make_home reoffer)
  id=$(receive "$home" %50 'keep this body private') || fail "receive fixture failed"
  out=$(FM_HOME="$home" FMPEER_NOW_OVERRIDE=1000 "$ROOT/bin/fm-peer-relay-poll.sh")
  [ "$out" = "peer-relay-request $id" ] || fail "first peer poll must offer request id"
  out=$(FM_HOME="$home" FMPEER_NOW_OVERRIDE=1000 "$ROOT/bin/fm-peer-relay-poll.sh")
  [ -z "$out" ] || fail "fresh offer marker must suppress a duplicate"
  touch -t 202001010000 "$home/state/peer-relay/offered/$id"
  out=$(FM_HOME="$home" FMPEER_NOW_OVERRIDE=2000000000 "$ROOT/bin/fm-peer-relay-poll.sh")
  [ "$out" = "peer-relay-request $id" ] || fail "unanswered request must re-offer after timeout"
  assert_not_contains "$out" 'keep this body private' "request body leaked from peer poll"
  pass "peer poll offers ids once and re-offers an unanswered request after timeout"
}

test_watcher_queues_ids_only_check_wake() {
  local home id out rc drain
  home=$(make_home wake)
  id=$(receive "$home" %51 'SENTINEL secret peer body') || fail "receive fixture failed"
  out=$(run_watcher_bounded "$home" 2>/dev/null)
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher never surfaced peer request"
  assert_contains "$out" "peer-relay-request $id" "watcher must surface request id"
  assert_not_contains "$out" 'SENTINEL secret peer body' "message body leaked into watcher output"
  assert_grep "peer-relay-request $id" "$home/state/.wake-queue" \
    "watcher must durably queue peer request check"
  assert_no_grep 'SENTINEL secret peer body' "$home/state/.wake-queue" \
    "message body leaked into wake queue"
  drain=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$drain" "$(printf '\tcheck\t')" "drain must preserve check wake kind"
  assert_contains "$drain" "peer-relay-request $id" "drain must preserve request id"
  pass "authenticated watcher dispatch queues and drains an ids-only peer check wake"
}

make_ssh_stub() {
  local dir=$1
  cat > "$dir/ssh-stub" <<'SH'
#!/usr/bin/env bash
: > "$FMPEER_SSH_ARGS_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$FMPEER_SSH_ARGS_LOG"; done
cat > "$FMPEER_SSH_STDIN_LOG"
exit "${FMPEER_SSH_EXIT:-0}"
SH
  chmod +x "$dir/ssh-stub"
  printf '%s\n' "$dir/ssh-stub"
}

test_reply_targets_exact_carbon_pane_and_resolves() {
  local home id ssh_stub reply dir
  home=$(make_home reply)
  id=$(receive "$home" %88 'what is the answer?') || fail "receive fixture failed"
  ssh_stub=$(make_ssh_stub "$home")
  reply="$home/reply.txt"
  printf 'Captain, the answer is 42.' > "$reply"
  FM_HOME="$home" FMPEER_SSH_BIN="$ssh_stub" \
    FMPEER_SSH_ARGS_LOG="$home/ssh.args" FMPEER_SSH_STDIN_LOG="$home/ssh.stdin" \
    FMPEER_NOW_OVERRIDE=1785600100 \
    "$ROOT/bin/fm-peer-relay-reply.sh" send "$id" --text-file "$reply" >/dev/null \
    || fail "reply helper failed"
  [ "$(cat "$home/ssh.args")" = $'--\ncarbon\n/Users/morris/.local/bin/fm-peer-relay-tell.sh\n--deliver\n%88' ] \
    || fail "reply SSH command did not target the exact recorded carbon pane"
  [ "$(cat "$home/ssh.stdin")" = 'Captain, the answer is 42.' ] \
    || fail "reply body did not travel on SSH stdin"
  dir="$home/state/peer-relay/requests/$id"
  assert_grep 'state=resolved' "$dir/status" "successful SSH reply must resolve request"
  [ "$(cat "$dir/reply")" = 'Captain, the answer is 42.' ] \
    || fail "durable reply record changed body"
  pass "reply uses ssh carbon plus exact pane id and resolves only on success"
}

test_reply_failure_is_uncertain_and_not_retryable() {
  local home id ssh_stub reply rc
  home=$(make_home uncertain)
  id=$(receive "$home" %89 'answer me once') || fail "receive fixture failed"
  ssh_stub=$(make_ssh_stub "$home")
  reply="$home/reply.txt"
  printf 'Captain, one attempt.' > "$reply"
  FM_HOME="$home" FMPEER_SSH_BIN="$ssh_stub" FMPEER_SSH_EXIT=7 \
    FMPEER_SSH_ARGS_LOG="$home/ssh.args" FMPEER_SSH_STDIN_LOG="$home/ssh.stdin" \
    "$ROOT/bin/fm-peer-relay-reply.sh" send "$id" --text-file "$reply" >/dev/null 2>&1
  rc=$?
  expect_code 7 "$rc" "uncertain delivery exit"
  assert_grep 'state=delivery-uncertain' "$home/state/peer-relay/requests/$id/status" \
    "failed SSH must record uncertainty"
  FM_HOME="$home" FMPEER_SSH_BIN="$ssh_stub" \
    FMPEER_SSH_ARGS_LOG="$home/ssh.args.2" FMPEER_SSH_STDIN_LOG="$home/ssh.stdin.2" \
    "$ROOT/bin/fm-peer-relay-reply.sh" send "$id" --text-file "$reply" >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "blind retry refusal"
  assert_absent "$home/ssh.args.2" "blind retry must not reach SSH"
  pass "failed reply records delivery uncertainty and refuses blind retry"
}

make_client_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FMPEER_TMUX_LOG"
if [ "$1" = display-message ]; then
  case "$*" in
    *'#{pane_id}|#{session_name}|#{window_id}'*) printf '%s\n' '%73|orchestrator|@11' ;;
    *'#{pane_id}'*) printf '%s\n' '%73' ;;
  esac
fi
SH
  cat > "$fakebin/hostname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' carbon
SH
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
: > "$FMPEER_CLIENT_SSH_ARGS"
for arg in "$@"; do printf '%s\n' "$arg" >> "$FMPEER_CLIENT_SSH_ARGS"; done
cat > "$FMPEER_CLIENT_SSH_STDIN"
printf '%s\n' peer-test-id
SH
  chmod +x "$fakebin/tmux" "$fakebin/hostname" "$fakebin/ssh"
  printf '%s\n' "$fakebin"
}

test_client_captures_identity_and_builds_remote_command() {
  local dir fakebin out envelope
  dir="$TMP_ROOT/client-send"; mkdir -p "$dir"
  fakebin=$(make_client_stubs "$dir")
  out=$(PATH="$fakebin:$PATH" TMUX_PANE=%73 FMPEER_TMUX_LOG="$dir/tmux.log" \
    FMPEER_CLIENT_SSH_ARGS="$dir/ssh.args" FMPEER_CLIENT_SSH_STDIN="$dir/ssh.stdin" \
    "$ROOT/bin/fm-peer-relay-tell.sh" 'tell firstmate to inspect carbon') \
    || fail "carbon client send failed"
  [ "$out" = peer-test-id ] || fail "client did not relay receiver request id"
  [ "$(cat "$dir/ssh.args")" = $'--\nmirage\nFM_HOME=$HOME/kun-agent-workspace $HOME/kun-agent-workspace/bin/fm-peer-relay-receive.sh' ] \
    || fail "client SSH command shape changed"
  envelope=$(cat "$dir/ssh.stdin")
  assert_contains "$envelope" $'fm-peer-relay-v1\norigin_host=carbon\npane_id=%73\nsession_name=orchestrator\nwindow_id=@11\nclient_epoch=' \
    "client envelope must carry captured exact identity"
  assert_contains "$envelope" $'\n\ntell firstmate to inspect carbon' \
    "client envelope must carry raw message after blank line"
  pass "carbon client captures its own exact pane identity and calls mirage receiver"
}

test_client_delivery_uses_literal_text_then_separate_enter() {
  local dir fakebin
  dir="$TMP_ROOT/client-deliver"; mkdir -p "$dir"
  fakebin=$(make_client_stubs "$dir")
  printf 'Captain, delivered.' | PATH="$fakebin:$PATH" FMPEER_TMUX_LOG="$dir/tmux.log" \
    "$ROOT/bin/fm-peer-relay-tell.sh" --deliver %73 \
    || fail "client reply delivery failed"
  assert_grep 'display-message -p -t %73 #{pane_id}' "$dir/tmux.log" \
    "delivery must verify exact pane"
  assert_grep 'send-keys -t %73 -l -- Captain, delivered.' "$dir/tmux.log" \
    "delivery must type reply literally"
  assert_grep 'send-keys -t %73 Enter' "$dir/tmux.log" \
    "delivery must submit with separate Enter"
  pass "carbon delivery types literal text once and submits with a separate Enter"
}

test_supervision_needed_by_peer_poll() {
  local home
  home="$TMP_ROOT/supervision"; mkdir -p "$home/state"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-supervision-lib.sh"
  fm_supervision_status "$home/state"
  [ "$FM_SUP_NEEDED" = false ] || fail "empty home must not need supervision"
  : > "$home/state/peer-relay-watch.check.sh"
  fm_supervision_status "$home/state"
  [ "$FM_SUP_NEEDED" = true ] || fail "peer poll must keep supervision live"
  pass "peer-relay activation requires supervision even without project work"
}

test_bootstrap_activation_and_optout
test_receive_publishes_private_pending_record
test_receive_rejects_nonssh_and_bad_identity
test_poll_offers_once_and_reoffers_unanswered
test_watcher_queues_ids_only_check_wake
test_reply_targets_exact_carbon_pane_and_resolves
test_reply_failure_is_uncertain_and_not_retryable
test_client_captures_identity_and_builds_remote_command
test_client_delivery_uses_literal_text_then_separate_enter
test_supervision_needed_by_peer_poll
