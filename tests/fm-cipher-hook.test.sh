#!/usr/bin/env bash
# Tests for the authenticated Cipher/Hermes event and receive bridge.
# Synthetic localhost servers and isolated state prove exact-body HMAC V2,
# explicit legacy compatibility, event/head dedupe, safe holds, iinvy merge
# ownership, and pane-independent authenticated return delivery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

HOOK="$ROOT/bin/fm-cipher-hook.sh"
RECEIVE="$ROOT/bin/fm-cipher-receive.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-cipher-hook-tests)
SECRET='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
HEAD_A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
HEAD_B='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

cleanup() {
  local pid_file pid
  for pid_file in "$TMP_ROOT"/*/server.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup || true
  rm -rf "$TMP_ROOT"
  return 0
}
trap cleanup EXIT

start_server() { # <dir> <mode>
  local dir=$1 mode=$2 port_file="$1/server.port" log="$1/server.log" pid i
  : > "$log"
  rm -f "$port_file"
  python3 - "$port_file" "$log" "$dir/config/cipher-hooks.secret" "$mode" >/dev/null 2>&1 <<'PY' &
import hashlib
import hmac
import http.server
import json
import sys
import time

port_file, log_path, secret_path, mode = sys.argv[1:]
secret = open(secret_path, "rb").read().decode("ascii").strip().encode("ascii")

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        timestamp = self.headers.get("X-Webhook-Timestamp")
        v2 = self.headers.get("X-Webhook-Signature-V2")
        v1 = self.headers.get("X-Webhook-Signature")
        request_id = self.headers.get("X-Request-ID")
        expected_v2 = None
        if timestamp is not None:
            expected_v2 = hmac.new(secret, timestamp.encode("ascii") + b"." + body, hashlib.sha256).hexdigest()
        expected_v1 = hmac.new(secret, body, hashlib.sha256).hexdigest()
        record = {
            "body": json.loads(body),
            "request_id": request_id,
            "idempotency_key": self.headers.get("Idempotency-Key"),
            "timestamp": timestamp,
            "timestamp_fresh": timestamp is not None and abs(int(time.time()) - int(timestamp)) <= 300,
            "v2_present": v2 is not None,
            "v2_valid": v2 is not None and expected_v2 == v2,
            "v1_present": v1 is not None,
            "v1_valid": v1 is not None and expected_v1 == v1,
        }
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        if mode == "delay":
            time.sleep(1.0)
        if mode == "http500":
            self.send_response(500)
            response = b"{}"
        elif mode == "invalid":
            self.send_response(202)
            response = b'{"status":"accepted","route":"wrong","event":"unknown","delivery_id":"wrong"}'
        elif mode == "duplicate":
            self.send_response(200)
            response = json.dumps({
                "status": "duplicate",
                "delivery_id": request_id,
            }, separators=(",", ":")).encode("utf-8")
        else:
            self.send_response(202)
            response = json.dumps({
                "status": "accepted",
                "route": self.path.rsplit("/", 1)[-1],
                "event": record["body"]["event_type"],
                "delivery_id": request_id,
            }, separators=(",", ":")).encode("utf-8")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        try:
            self.wfile.write(response)
        except BrokenPipeError:
            pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="ascii") as handle:
    handle.write(str(server.server_port))
server.serve_forever()
PY
  pid=$!
  printf '%s\n' "$pid" > "$dir/server.pid"
  i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$port_file" ] && break
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$port_file" ] || fail "fake Cipher server did not start"
  cat "$port_file"
}

stop_server() { # <pid>
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

make_case() { # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/wt" "$dir/fakebin"
  printf '%s\n' "$SECRET" > "$dir/config/cipher-hooks.secret"
  chmod 0600 "$dir/config/cipher-hooks.secret"
  cat > "$dir/fakebin/fm-crew-state" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_CREW_STATE_MARKER:-}" ] || : > "$FM_TEST_CREW_STATE_MARKER"
printf '%s\n' "${FM_TEST_CREW_STATE:-state: unknown · source: none}"
SH
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") printf '%s\n' "${FM_TEST_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
esac
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_TMUX_MARKER:-}" ] || : > "$FM_TEST_TMUX_MARKER"
case "${1:-}" in
  list-panes) printf 'firstmate:0 claude\nfirstmate:1 pi\n' ;;
esac
exit 99
SH
  chmod +x "$dir/fakebin/"*
  printf '%s\n' "$dir"
}

write_config() { # <dir> <port> <decision> <pr-route>
  cat > "$1/config/cipher-hooks" <<EOF
version=1
decision_route=$3
iinvy_pr_ready_route=$4
endpoint=http://127.0.0.1:$2/webhooks/firstmate-hook
secret_file=$1/config/cipher-hooks.secret
EOF
  chmod 0600 "$1/config/cipher-hooks"
}

run_hook() { # <dir> <args...>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_CONFIG_OVERRIDE="$dir/config" \
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  PATH="$dir/fakebin:$PATH" \
    "$HOOK" "$@"
}

run_pr_check() { # <dir> <id> <url>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_CONFIG_OVERRIDE="$dir/config" \
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

run_pr_merge() { # <dir> <id> <url>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_CONFIG_OVERRIDE="$dir/config" \
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  PATH="$dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

request_id_for_kind() { # <dir> <kind>
  python3 - "$1/state/cipher-hooks/requests" "$2" <<'PY'
import glob, json, sys
for path in glob.glob(sys.argv[1] + "/*.json"):
    value = json.load(open(path, encoding="utf-8"))
    if value["event_type"] == sys.argv[2]:
        print(value["request_id"])
PY
}

test_v2_decision_and_pr_delivery_dedupe() {
  local dir port count decision_id pr_id
  dir=$(make_case delivery)
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/decision-task.meta" \
    "window=fm-decision-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes"
  # shellcheck disable=SC2016 # Literal command substitution probes prose isolation.
  printf 'needs-decision [key=route]: arbitrary worker prose $(touch /tmp/never) SECRET_PROSE\n' \
    > "$dir/state/decision-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog
## In flight
- [ ] decision-task - choose route https://github.com/example/project/issues/7 (kind: ship)
EOF

  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision decision-task route \
    > "$dir/decision.out" 2> "$dir/decision.err" || fail "decision event delivery failed"
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision decision-task route \
    >> "$dir/decision.out" 2>> "$dir/decision.err" || fail "decision event dedupe failed"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "logical decision gate was delivered $count times"
  jq -e 'select(.v2_present and .v2_valid and .timestamp_fresh and (.v1_present | not))
    | select(.request_id == .idempotency_key and .request_id == .body.request_id)
    | select(.body.event_type == "needs-decision" and .body.decision_id == "route")' \
    "$dir/server.log" >/dev/null || fail "production delivery did not use replay-protected generic HMAC V2"
  assert_no_grep 'SECRET_PROSE' "$dir/server.log" "worker prose leaked into the decision payload"
  decision_id=$(request_id_for_kind "$dir" needs-decision)
  [ -n "$decision_id" ] || fail "decision request record missing"
  assert_present "$dir/state/cipher-hooks/acks/$decision_id.json" "decision acknowledgement was not durable"
  jq -e --arg id "$decision_id" '
    select(.http_status == 202)
    | select(.gateway_ack == {status:"accepted",route:"firstmate-hook",event:"needs-decision",delivery_id:$id})
  ' "$dir/state/cipher-hooks/acks/$decision_id.json" >/dev/null \
    || fail "accepted acknowledgement was not bound to the real Hermes HTTP 202 shape"

  fm_write_meta "$dir/state/decision-task.meta" \
    "window=fm-decision-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/example/project/pull/4" "pr_head=$HEAD_A"
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision decision-task route \
    >> "$dir/decision.out" 2>> "$dir/decision.err" \
    || fail "decision dedupe failed once PR metadata was recorded"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "recorded PR metadata re-delivered the same logical decision"

  cat >> "$dir/data/backlog.md" <<'EOF'
- [ ] pr-task - fix production path https://github.com/morris2spears/iinvy/issues/8 (kind: ship)
EOF
  fm_write_meta "$dir/state/pr-task.meta" \
    "window=fm-pr-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/morris2spears/iinvy/pull/9" "pr_head=$HEAD_A"
  printf 'done: PR https://github.com/morris2spears/iinvy/pull/9 checks green\n' > "$dir/state/pr-task.status"
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" pr-ready pr-task https://github.com/morris2spears/iinvy/pull/9 \
    > "$dir/pr.out" 2> "$dir/pr.err" || fail "PR-ready event delivery failed"
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" pr-ready pr-task https://github.com/morris2spears/iinvy/pull/9 \
    >> "$dir/pr.out" 2>> "$dir/pr.err" || fail "PR-ready event dedupe failed"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 2 ] || fail "exact PR head was not delivered once"
  jq -s -e '.[1] | select(.v2_valid and (.v1_present | not))
    | select(.body.event_type == "iinvy-pr-ready")
    | select(.body.repository == "morris2spears/iinvy")
    | select(.body.pr_head_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    | select(.body.issue_url == "https://github.com/morris2spears/iinvy/issues/8")' \
    "$dir/server.log" >/dev/null || fail "PR-ready payload or HMAC V2 binding was wrong"
  pr_id=$(request_id_for_kind "$dir" iinvy-pr-ready)
  assert_present "$dir/state/cipher-hooks/acks/$pr_id.json" "PR acknowledgement was not durable"

  perl -0pi -e "s/pr_head=$HEAD_A/pr_head=$HEAD_B/" "$dir/state/pr-task.meta"
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" pr-ready pr-task https://github.com/morris2spears/iinvy/pull/9 \
    >/dev/null 2>&1 || fail "advanced PR head event failed"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 3 ] || fail "advanced PR head did not produce exactly one new event"
  pass "Cipher events use replay-protected HMAC V2 and dedupe by decision gate and exact PR head"
}

test_legacy_v1_is_explicit_test_only() {
  local dir port
  dir=$(make_case legacy)
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/legacy-task.meta" \
    "window=fm-legacy-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship"
  printf 'needs-decision [key=compat]: compatibility test\n' > "$dir/state/legacy-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] legacy-task - compatibility https://github.com/example/project/issues/8 (kind: ship)
EOF
  FM_CIPHER_SIGNATURE_VERSION=legacy-v1 FM_CIPHER_ALLOW_LEGACY_V1_TEST=1 \
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision legacy-task compat >/dev/null 2>&1 \
    || fail "explicit legacy compatibility delivery failed"
  jq -e 'select(.v1_present and .v1_valid and (.v2_present | not) and (.timestamp == null))' \
    "$dir/server.log" >/dev/null || fail "legacy body-only fallback was not explicitly selectable for compatibility testing"
  pass "legacy body-only HMAC is isolated behind an explicit tested compatibility seam"
}

test_real_duplicate_response_is_accepted_exactly() {
  local dir port request_id
  dir=$(make_case duplicate)
  port=$(start_server "$dir" duplicate)
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/duplicate-task.meta" \
    "window=fm-duplicate-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship"
  printf 'needs-decision [key=replay]: retry the same delivery\n' > "$dir/state/duplicate-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] duplicate-task - retry https://github.com/example/project/issues/10 (kind: ship)
EOF
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision duplicate-task replay >/dev/null 2>&1 \
    || fail "real Hermes duplicate response was not accepted"
  request_id=$(request_id_for_kind "$dir" needs-decision)
  jq -e --arg id "$request_id" '
    select(.http_status == 200)
    | select(.gateway_ack == {status:"duplicate",delivery_id:$id})
  ' "$dir/state/cipher-hooks/acks/$request_id.json" >/dev/null \
    || fail "duplicate acknowledgement was not bound to the real HTTP 200 adapter shape"
  pass "real Hermes HTTP 200 duplicate response is accepted exactly"
}

test_malformed_and_unavailable_hold_without_leakage() {
  local dir port pid rc first_lines second_lines request_id
  dir=$(make_case failures)
  port=$(start_server "$dir" accepted)
  pid=$(cat "$dir/server.pid")
  stop_server "$pid"
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/fail-task.meta" \
    "window=fm-fail-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship"
  printf 'needs-decision [key=network]: choose retry\n' > "$dir/state/fail-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] fail-task - network https://github.com/example/project/issues/11 (kind: ship)
EOF

  set +e
  FM_CIPHER_RETRIES=2 FM_CIPHER_RETRY_DELAY_SECS=0 \
  FM_TEST_CREW_STATE='state: parked · source: status-log · choose retry' \
    run_hook "$dir" needs-decision fail-task network > "$dir/fail.out" 2> "$dir/fail.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unavailable gateway must hold"
  first_lines=$(grep -c '^CIPHER_HOOK:' "$dir/fail.err" || true)
  [ "$first_lines" = 1 ] || fail "unavailable route did not surface exactly one actionable diagnostic"
  request_id=$(request_id_for_kind "$dir" needs-decision)
  assert_present "$dir/state/cipher-hooks/holds/$request_id.json" "unavailable route did not create a durable hold"
  assert_present "$dir/state/cipher-hooks/sent/$request_id.json" "unavailable route did not record delivery attempts"

  set +e
  FM_CIPHER_RETRIES=1 FM_CIPHER_RETRY_DELAY_SECS=0 \
  FM_TEST_CREW_STATE='state: parked · source: status-log · choose retry' \
    run_hook "$dir" needs-decision fail-task network > "$dir/fail2.out" 2> "$dir/fail2.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "replayed unavailable gateway must remain held"
  second_lines=$(grep -c '^CIPHER_HOOK:' "$dir/fail2.err" || true)
  [ "$second_lines" = 0 ] || fail "same held event repeated its actionable diagnostic"
  ! grep -R -F "$SECRET" "$dir/state" "$dir/fail.out" "$dir/fail.err" "$dir/fail2.out" "$dir/fail2.err" >/dev/null \
    || fail "HMAC secret leaked into state or command output"

  set +e
  FM_TEST_CREW_STATE='state: parked · source: status-log' \
    run_hook "$dir" needs-decision '../escape' network >/dev/null 2> "$dir/malformed.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "traversal task id must be rejected"
  assert_absent "$dir/state/escape.meta" "malformed task created an artifact"
  set +e
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green' \
    run_hook "$dir" pr-ready fail-task 'https://evil.example/x/y/pull/1' >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "unexpected PR host must be rejected"
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    python3 "$ROOT/bin/fm-cipher-hook.py" deliver unexpected fail-task network \
    >/dev/null 2> "$dir/unexpected.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "unexpected event type must be rejected"
  pass "malformed inputs are rejected and unavailable delivery holds once without secret leakage"
}

prepare_pr_case() { # <dir> <id> <repo> [head] [current-state]
  local dir=$1 id=$2 repo=$3 head=${4:-$HEAD_A}
  local crew_state=${5:-'state: done · source: run-step · checks green: PR ready for review'}
  fm_write_meta "$dir/state/$id.meta" \
    "window=fm-$id" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes"
  : > "$dir/gh-axi.log"
  export FM_TEST_HEAD=$head
  export FM_TEST_CREW_STATE=$crew_state
  run_pr_check "$dir" "$id" "https://github.com/$repo/pull/19"
}

test_timeout_is_durable_hold() {
  local dir port rc request_id
  dir=$(make_case timeout)
  port=$(start_server "$dir" delay)
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/timeout-task.meta" \
    "window=fm-timeout-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship"
  printf 'needs-decision [key=slow]: wait for route\n' > "$dir/state/timeout-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] timeout-task - timeout https://github.com/example/project/issues/12 (kind: ship)
EOF
  set +e
  FM_CIPHER_RETRIES=1 FM_CIPHER_TIMEOUT_SECS=0.1 FM_CIPHER_RETRY_DELAY_SECS=0 \
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision timeout-task slow > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "timed-out gateway must hold"
  request_id=$(request_id_for_kind "$dir" needs-decision)
  jq -e 'select(.reason == "timeout")' "$dir/state/cipher-hooks/holds/$request_id.json" >/dev/null \
    || fail "timeout did not create its bounded durable hold"
  pass "gateway timeout is a durable fail-safe hold"
}

assert_direct_merge_held() { # <dir> <id> <repo> <label>
  local dir=$1 id=$2 repo=$3 label=$4 rc
  : > "$dir/gh-axi.log"
  set +e
  run_pr_merge "$dir" "$id" "https://github.com/$repo/pull/19" \
    > "$dir/$id.merge.out" 2> "$dir/$id.merge.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "$label must refuse autonomous merge"
  assert_no_grep 'pr merge' "$dir/gh-axi.log" "$label reached gh-axi merge"
}

test_pr_check_allowlist_and_safe_holds() {
  local dir rc port count repo
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  diff <(printf '%s\n' "${FM_CIPHER_GATED_REPOSITORIES[@]}") \
    <(grep -v -e '^#' -e '^$' "$ROOT/bin/fm-cipher-hook-repositories") >/dev/null \
    || fail "the shell gate list and the Cipher allowlist file disagree"
  fm_cipher_repo_gated Morris2Spears/iinvy || fail "mixed-case iinvy owner was not recognized as gated"
  fm_cipher_repo_gated example/other && fail "an unrelated repository was treated as gated"
  dir=$(make_case pr-check)
  export FM_TEST_CREW_STATE_MARKER="$dir/crew-state.called"
  set +e
  prepare_pr_case "$dir" other-task example/other > "$dir/other.out" 2> "$dir/other.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "non-allowlisted PR-ready path changed"
  assert_absent "$dir/state/cipher-hooks" "non-allowlisted PR spent a Cipher event"
  assert_absent "$dir/crew-state.called" "non-allowlisted PR consulted Cipher current-state routing"

  rm -f "$dir/crew-state.called"
  set +e
  prepare_pr_case "$dir" waiting-iinvy morris2spears/iinvy "$HEAD_A" \
    'state: working · source: run-step · ci running' > "$dir/waiting.out" 2> "$dir/waiting.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "non-green iinvy PR registration should keep waiting for checks"
  assert_absent "$dir/state/cipher-hooks" "non-green iinvy PR emitted a Cipher event"

  for repo in morris2spears/iinvy morris2spears/iinvy-storefront; do
    rm -f "$dir/config/cipher-hooks" "$dir/crew-state.called"
    set +e
    prepare_pr_case "$dir" "missing-${repo##*/}" "$repo" > "$dir/missing.out" 2> "$dir/missing.err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$repo missing hook must hold"
    assert_direct_merge_held "$dir" "missing-${repo##*/}" "$repo" "$repo missing hook"
  done

  rm -f "$dir/config/cipher-hooks" "$dir/crew-state.called"
  set +e
  prepare_pr_case "$dir" mixed-case-iinvy Morris2Spears/iinvy > "$dir/mixed.out" 2> "$dir/mixed.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a mixed-case iinvy owner must still be gated and held"
  assert_direct_merge_held "$dir" mixed-case-iinvy Morris2Spears/iinvy "mixed-case iinvy owner"

  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled disabled
  set +e
  prepare_pr_case "$dir" disabled-storefront morris2spears/iinvy-storefront > "$dir/disabled.out" 2> "$dir/disabled.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "disabled storefront route must hold"
  assert_direct_merge_held "$dir" disabled-storefront morris2spears/iinvy-storefront "disabled storefront route"

  stop_server "$(cat "$dir/server.pid")"
  write_config "$dir" "$port" enabled enabled
  set +e
  prepare_pr_case "$dir" unavailable-iinvy morris2spears/iinvy > "$dir/unavailable.out" 2> "$dir/unavailable.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unavailable iinvy route must hold"
  assert_direct_merge_held "$dir" unavailable-iinvy morris2spears/iinvy "unavailable iinvy route"

  port=$(start_server "$dir" invalid)
  write_config "$dir" "$port" enabled enabled
  set +e
  prepare_pr_case "$dir" invalid-iinvy morris2spears/iinvy > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "invalid gateway acknowledgement must hold"
  assert_direct_merge_held "$dir" invalid-iinvy morris2spears/iinvy "invalid iinvy acknowledgement"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" -ge 1 ] || fail "invalid-response fake gateway was not exercised"
  pass "only iinvy repositories emit at checks-green and every route failure holds them"
}

test_iinvy_merge_requires_cipher_actor_and_exact_head() {
  local dir port request_id new_request rc
  dir=$(make_case merge)
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  prepare_pr_case "$dir" merge-task morris2spears/iinvy >/dev/null 2>&1 \
    || fail "accepted iinvy PR-ready event failed"
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)

  : > "$dir/gh-axi.log"
  set +e
  run_pr_merge "$dir" merge-task https://github.com/morris2spears/iinvy/pull/19 \
    > "$dir/direct.out" 2> "$dir/direct.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate direct iinvy merge must remain held after delivery"
  assert_no_grep 'pr merge' "$dir/gh-axi.log" "direct iinvy path bypassed Cipher actor ownership"

  : > "$dir/gh-axi.log"
  set +e
  FM_TEST_HEAD=$HEAD_A FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
    run_hook "$dir" merge merge-task https://github.com/morris2spears/iinvy/pull/19 "$request_id" \
    > "$dir/red.out" 2> "$dir/red.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "Cipher actor must not merge after checks regress"
  assert_no_grep 'pr merge' "$dir/gh-axi.log" "checks-regressed PR reached merge"

  : > "$dir/gh-axi.log"
  FM_TEST_HEAD=$HEAD_A FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" merge merge-task https://github.com/morris2spears/iinvy/pull/19 "$request_id" \
    > "$dir/cipher-merge.out" 2> "$dir/cipher-merge.err" || fail "Cipher guarded merge failed"
  assert_grep "pr merge 19 --repo morris2spears/iinvy --squash --match-head-commit $HEAD_A" \
    "$dir/gh-axi.log" "Cipher merge did not preserve guarded merge metadata and exact-head binding"

  # A later head produces a new event but cannot ride the inspected old request.
  : > "$dir/gh-axi.log"
  set +e
  FM_TEST_HEAD=$HEAD_B FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" merge merge-task https://github.com/morris2spears/iinvy/pull/19 "$request_id" \
    > "$dir/advanced.out" 2> "$dir/advanced.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "advanced PR head must stop the old Cipher inspection"
  assert_no_grep 'pr merge' "$dir/gh-axi.log" "advanced head merged under an old Cipher request"
  new_request=$(python3 - "$dir/state/cipher-hooks/requests" <<'PY'
import glob, json, sys
rows = []
for path in glob.glob(sys.argv[1] + "/*.json"):
    value = json.load(open(path, encoding="utf-8"))
    if value["event_type"] == "iinvy-pr-ready":
        rows.append((value["pr_head_sha"], value["request_id"]))
for head, request_id in rows:
    if head.startswith("bbbb"):
        print(request_id)
PY
)
  [ -n "$new_request" ] || fail "advanced head did not create a replacement event"
  pass "iinvy merges require Cipher's actor path and the exact inspected PR head"
}

test_receive_api_ignores_self_repo_worker_pane() {
  local dir port request_id comment before after
  dir=$(make_case receive)
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/decision-task.meta" \
    "window=firstmate:fm-decision-task" "endpoint_task_id=decision-task" \
    "worktree=$dir/wt" "project=$ROOT" "kind=ship" "mode=no-mistakes"
  printf 'needs-decision [key=route]: choose route\n' > "$dir/state/decision-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] decision-task - choose route https://github.com/example/project/issues/7 (kind: ship)
EOF
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision decision-task route >/dev/null 2>&1 \
    || fail "receive fixture event failed"
  request_id=$(request_id_for_kind "$dir" needs-decision)

  # Reproduce the live ambiguity: a Claude primary plus a Pi self-repo ship pane,
  # with metadata proving the latter is a task in its own worktree.
  fm_write_meta "$dir/state/self-repo-worker.meta" \
    "window=firstmate:1" "endpoint_task_id=self-repo-worker" \
    "worktree=$ROOT" "project=$ROOT" "harness=pi" "kind=ship" "mode=no-mistakes"
  comment='https://github.com/example/project/issues/7#issuecomment-12345'
  : > "$dir/state/.wake-queue"
  rm -f "$dir/tmux.called"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
  FM_TEST_TMUX_MARKER="$dir/tmux.called" PATH="$dir/fakebin:$PATH" \
    "$RECEIVE" decision-comment decision-task "$request_id" "$comment" \
    > "$dir/receive.out" 2> "$dir/receive.err" || fail "pane-independent Cipher receive failed"
  assert_absent "$dir/tmux.called" "receive command scanned ambiguous primary/task panes"
  assert_grep "cipher-comment decision-comment decision-task $request_id $comment" \
    "$dir/state/.wake-queue" "receive command did not queue the authenticated GitHub pointer"
  assert_present "$dir/state/cipher-receive.turn-ended" \
    "receive command did not publish the content-free watcher edge"
  before=$(wc -l < "$dir/state/.wake-queue" | tr -d ' ')
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
  FM_TEST_TMUX_MARKER="$dir/tmux.called" PATH="$dir/fakebin:$PATH" \
    "$RECEIVE" decision-comment decision-task "$request_id" "$comment" >/dev/null 2>&1 \
    || fail "receive dedupe replay failed"
  after=$(wc -l < "$dir/state/.wake-queue" | tr -d ' ')
  [ "$before" = "$after" ] || fail "authenticated receive duplicated its durable notification"
  assert_absent "$dir/tmux.called" "receive replay weakened exactly-one-primary transport safety"
  pass "authenticated receive routes by task identity when a self-repo worker pane is present"
}

test_v2_decision_and_pr_delivery_dedupe
test_legacy_v1_is_explicit_test_only
test_real_duplicate_response_is_accepted_exactly
test_malformed_and_unavailable_hold_without_leakage
test_timeout_is_durable_hold
test_pr_check_allowlist_and_safe_holds
test_iinvy_merge_requires_cipher_actor_and_exact_head
test_receive_api_ignores_self_repo_worker_pane
