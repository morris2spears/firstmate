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
REPOSITORIES="$ROOT/bin/fm-cipher-repositories.sh"
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

start_server() { # <dir> <mode> [fixed-port]
  local dir=$1 mode=$2 fixed_port=${3:-0} port_file="$1/server.port" log="$1/server.log" pid i
  : > "$log"
  rm -f "$port_file"
  python3 - "$port_file" "$log" "$dir/config/cipher-hooks.secret" "$mode" "$fixed_port" >/dev/null 2>&1 <<'PY' &
import hashlib
import hmac
import http.server
import json
import sys
import time

port_file, log_path, secret_path, mode, fixed_port = sys.argv[1:]
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

server = http.server.ThreadingHTTPServer(("127.0.0.1", int(fixed_port)), Handler)
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
  # The forge snapshot query resolves state, mergeability, head, and the check
  # rollup verdict in gh's own jq, so the fake answers with that one line:
  # "<state> <mergeStateStatus> <head> <passed-rollup>". A pull request with no
  # check run of its own is the default, and is never green.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# FM_TEST_GH_FAIL is a forge that cannot answer right now: gh exits non-zero
# with no output, the way an auth, network, or rate-limit failure does.
[ -z "${FM_TEST_GH_FAIL:-}" ] || exit 1
case "${1:-} ${2:-}" in
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '%s %s %s\n' "${FM_TEST_FORGE_GREEN:-CLOSED BLOCKED}" \
          "${FM_TEST_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
          "${FM_TEST_FORGE_CHECKS:-0}" ;;
      *) printf '%s\n' "${FM_TEST_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
    esac
    ;;
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

run_repositories() { # <dir> <args...>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_CONFIG_OVERRIDE="$dir/config" \
    "$REPOSITORIES" "$@"
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

test_note_keyed_decision_single_hook_and_park() {
  # Regression for firstmate#21: the observed iinvy#292 event wrote its key
  # token after the colon ("needs-decision: [key=...] ...") and never reached
  # the Cipher route. The note-placed key must fold to its intended key, emit
  # exactly one authenticated hook, and leave the parked worker unanswered.
  local dir port count open before after
  dir=$(make_case note-key)
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/issue292-task.meta" \
    "window=fm-issue292-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes"
  printf 'needs-decision: [key=issue292-cross-role] neutral entity or strict history roles\n' \
    > "$dir/state/issue292-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] issue292-task - cross-role https://github.com/example/project/issues/292 (kind: ship)
EOF
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$dir/state/issue292-task.status")
  case "$open" in
    issue292-cross-role$'\t'needs-decision$'\t'*) ;;
    *) fail "note-placed key did not fold to its intended decision key: $open" ;;
  esac

  before=$(shasum -a 256 "$dir/state/issue292-task.status" | awk '{print $1}')
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision issue292-task issue292-cross-role \
    > "$dir/note.out" 2> "$dir/note.err" || fail "note-keyed decision event delivery failed"
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision issue292-task issue292-cross-role \
    >> "$dir/note.out" 2>> "$dir/note.err" || fail "note-keyed decision dedupe failed"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "note-keyed decision was delivered $count times instead of once"
  jq -e 'select(.v2_present and .v2_valid and .timestamp_fresh)
    | select(.body.event_type == "needs-decision" and .body.decision_id == "issue292-cross-role")' \
    "$dir/server.log" >/dev/null || fail "note-keyed decision delivery was not authenticated with its key"
  after=$(shasum -a 256 "$dir/state/issue292-task.status" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "the hook answered or mutated the parked decision status"
  [ ! -s "$dir/gh-axi.log" ] || fail "the hook filed GitHub activity instead of parking: $(cat "$dir/gh-axi.log")"
  pass "a note-keyed current decision emits exactly one authenticated hook and stays parked"
}

test_resolve_decision_requires_and_follows_authenticated_answer() {
  # The "file a follow-up issue / keep the current PR scoped" branch settles a
  # decision, so the durable keyed closure must be impossible before the route
  # ran and the authenticated Cipher comment arrived, and automatic afterwards.
  local dir port rc request_id comment open count
  dir=$(make_case resolve)
  fm_write_meta "$dir/state/decision-task.meta" \
    "window=fm-decision-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes"
  printf 'needs-decision: [key=route] choose route\n' > "$dir/state/decision-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] decision-task - choose route https://github.com/example/project/issues/7 (kind: ship)
EOF

  # Disabled decision route: the existing-authority fallback stays exit 3 and
  # the keyed decision still cannot be closed as Cipher-answered.
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" disabled enabled
  set +e
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision decision-task route > "$dir/disabled.out" 2> "$dir/disabled.err"
  rc=$?
  set -e
  expect_code 3 "$rc" "disabled decision route must fall back to the existing authority"
  request_id=$(request_id_for_kind "$dir" needs-decision)
  [ -n "$request_id" ] || fail "disabled-route request identity was not recorded"
  set +e
  run_hook "$dir" resolve-decision decision-task "$request_id" \
    > "$dir/resolve-disabled.out" 2> "$dir/resolve-disabled.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "an unacknowledged decision must refuse durable Cipher resolution"

  # Enabled route, delivered and acknowledged, but no authenticated comment yet:
  # resolution still refuses, so a follow-up filing cannot bypass the answer.
  write_config "$dir" "$port" enabled enabled
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision decision-task route >/dev/null 2>&1 \
    || fail "enabled decision event delivery failed"
  set +e
  run_hook "$dir" resolve-decision decision-task "$request_id" \
    > "$dir/resolve-early.out" 2> "$dir/resolve-early.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "resolution before the authenticated comment must refuse"
  assert_grep 'no authenticated Cipher decision comment is recorded' "$dir/resolve-early.err" \
    "early resolution did not name the missing authenticated answer"
  assert_no_grep 'resolved' "$dir/state/decision-task.status" \
    "early resolution wrote a durable closure without the authenticated answer"

  # The authenticated decision comment arrives; resolution closes the keyed
  # decision durably and idempotently.
  comment='https://github.com/example/project/issues/7#issuecomment-9921'
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
  PATH="$dir/fakebin:$PATH" \
    "$RECEIVE" decision-comment decision-task "$request_id" "$comment" >/dev/null 2>&1 \
    || fail "authenticated decision-comment receive failed"
  run_hook "$dir" resolve-decision decision-task "$request_id" \
    > "$dir/resolve.out" 2> "$dir/resolve.err" || fail "accepted-comment resolution failed"
  assert_grep "resolved decision-task route" "$dir/resolve.out" \
    "resolution did not report the closed keyed decision"
  assert_grep "resolved [key=route]: Cipher decision accepted $comment" \
    "$dir/state/decision-task.status" "resolution did not append the durable keyed closure"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$dir/state/decision-task.status")
  [ -z "$open" ] || fail "the accepted Cipher answer left the keyed decision open: $open"
  run_hook "$dir" resolve-decision decision-task "$request_id" \
    > "$dir/resolve2.out" 2> "$dir/resolve2.err" || fail "idempotent resolution replay failed"
  [ ! -s "$dir/resolve2.out" ] || fail "resolution replay reported a second closure"
  count=$(grep -c 'resolved \[key=route\]' "$dir/state/decision-task.status")
  [ "$count" = 1 ] || fail "resolution replay duplicated the durable closure line"
  pass "durable keyed closure requires the authenticated Cipher answer and is idempotent"
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
  local dir port rc request_id system_python
  dir=$(make_case timeout)
  port=$(start_server "$dir" delay)
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/timeout-task.meta" \
    "window=fm-timeout-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship"
  printf 'needs-decision [key=slow]: wait for route\n' > "$dir/state/timeout-task.status"
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] timeout-task - timeout https://github.com/example/project/issues/12 (kind: ship)
EOF
  # Apple's stock Python exposes socket.timeout as an OSError but not a TimeoutError.
  system_python=/usr/bin/python3
  [ -x "$system_python" ] || system_python=$(command -v python3)
  set +e
  FM_CIPHER_PYTHON="$system_python" \
  FM_CIPHER_RETRIES=1 FM_CIPHER_TIMEOUT_SECS=0.1 FM_CIPHER_RETRY_DELAY_SECS=0 \
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision timeout-task slow > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "timed-out gateway must hold"
  request_id=$(request_id_for_kind "$dir" needs-decision)
  jq -e 'select(.reason == "timeout")' "$dir/state/cipher-hooks/holds/$request_id.json" >/dev/null \
    || fail "timeout did not create its bounded durable hold"
  pass "system Python gateway timeout is a durable fail-safe hold"
}

test_legacy_socket_timeout_is_classified_as_timeout() {
  local dir
  dir=$(make_case legacy-socket-timeout)
  python3 - "$ROOT/bin/fm-cipher-hook.py" > "$dir/out" 2> "$dir/err" <<'PY'
import importlib.util
import socket
import sys

spec = importlib.util.spec_from_file_location("fm_cipher_hook", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LegacySocketTimeout(OSError):
    pass


assert not issubclass(LegacySocketTimeout, TimeoutError), "stub must not inherit TimeoutError"


class Connection:
    def __init__(self, *_args, **_kwargs):
        pass

    def request(self, *_args, **_kwargs):
        raise LegacySocketTimeout("timed out")

    def close(self):
        pass


socket.timeout = LegacySocketTimeout
module.http.client.HTTPConnection = Connection
config = {
    "secret": b"0" * 64,
    "host": "127.0.0.1",
    "port": 1,
    "route": "/hooks/decision",
    "route_name": "decision",
}
result = module.post_once(config, b"{}", "req-1", "needs-decision", 0.1)
assert result == ("timeout", None, None), f"unexpected classification: {result}"
print(result[0])
PY
  [ "$(cat "$dir/out")" = "timeout" ] \
    || fail "socket.timeout that is not a TimeoutError was not classified as timeout"
  pass "legacy socket.timeout is classified as timeout on every runtime"
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
  local -a registered_repos
  local expected_repos=(
    morris2spears/iinvy
    morris2spears/iinvy-storefront
    morris2spears/iinvy-control-plane
    morris2spears/cutbot
    morris2spears/hermes-agent-cutbot
  )
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  dir=$(make_case pr-check)
  diff <(printf '%s\n' "${expected_repos[@]}") <(run_repositories "$dir" list) >/dev/null \
    || fail "the five existing repository registrations changed"
  run_repositories "$dir" contains Morris2Spears/iinvy \
    || fail "mixed-case iinvy owner was not recognized as gated"
  run_repositories "$dir" contains morris2spears/iinvy-control-plane \
    || fail "the control-plane repository was not recognized as gated"
  run_repositories "$dir" contains Morris2Spears/CutBot \
    || fail "mixed-case cutbot repository was not recognized as gated"
  run_repositories "$dir" contains Morris2Spears/Hermes-Agent-CutBot \
    || fail "mixed-case hermes-agent-cutbot repository was not recognized as gated"
  set +e
  run_repositories "$dir" contains morris2spears/realvis-studio
  rc=$?
  set -e
  expect_code 1 "$rc" "RealVis must not be registered before an explicit add"
  set +e
  run_repositories "$dir" contains example/other
  rc=$?
  set -e
  expect_code 1 "$rc" "an unrelated repository was treated as gated"
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

  run_repositories "$dir" add Morris2Spears/RealVis-Studio > "$dir/add.out" \
    || fail "RealVis registration failed"
  assert_grep 'registered: morris2spears/realvis-studio' "$dir/add.out" \
    "RealVis registration was not normalized"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    fm_cipher_repo_gated Morris2Spears/RealVis-Studio \
    || fail "the shell merge gate did not read the home registration"
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  prepare_pr_case "$dir" green-cutbot morris2spears/cutbot > "$dir/cutbot.out" 2> "$dir/cutbot.err" \
    || fail "green cutbot PR registration did not take the Cipher PR-ready path"
  prepare_pr_case "$dir" green-hermes-agent-cutbot morris2spears/hermes-agent-cutbot \
    > "$dir/hermes-agent-cutbot.out" 2> "$dir/hermes-agent-cutbot.err" \
    || fail "green hermes-agent-cutbot PR registration did not take the Cipher PR-ready path"
  prepare_pr_case "$dir" green-realvis-studio morris2spears/realvis-studio \
    > "$dir/realvis-studio.out" 2> "$dir/realvis-studio.err" \
    || fail "green realvis-studio PR registration did not take the Cipher PR-ready path"
  jq -s -e '
    length == 3
    and ([.[].body.repository] | sort
      == ["morris2spears/cutbot", "morris2spears/hermes-agent-cutbot", "morris2spears/realvis-studio"])
    and all(.[].body.event_type; . == "iinvy-pr-ready")
  ' "$dir/server.log" >/dev/null || fail "gated PR registrations did not emit the expected Cipher events"
  stop_server "$(cat "$dir/server.pid")"

  registered_repos=()
  while IFS= read -r repo; do
    registered_repos+=("$repo")
  done < <(run_repositories "$dir" list)
  for repo in "${registered_repos[@]}"; do
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
  pass "only Cipher-gated repositories emit at checks-green and every route failure holds them"
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

prepare_retry_pr_hold() { # <dir> <id> <port>
  local dir=$1 id=$2 port=$3 rc
  write_config "$dir" "$port" enabled enabled
  fm_write_meta "$dir/state/$id.meta" \
    "window=fm-$id" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/morris2spears/iinvy/pull/21" "pr_head=$HEAD_A"
  printf 'done: PR https://github.com/morris2spears/iinvy/pull/21 checks green\n' > "$dir/state/$id.status"
  cat >> "$dir/data/backlog.md" <<EOF
- [ ] $id - recovery https://github.com/morris2spears/iinvy/issues/16 (kind: ship)
EOF
  set +e
  FM_CIPHER_RETRIES=1 FM_CIPHER_RETRY_DELAY_SECS=0 \
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" pr-ready "$id" https://github.com/morris2spears/iinvy/pull/21 \
    > "$dir/$id.trigger.out" 2> "$dir/$id.trigger.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unavailable gateway must hold the $id trigger"
}

test_retry_held_after_gateway_recovery() {
  local dir port request_id out count
  dir=$(make_case retry)
  : > "$dir/data/backlog.md"
  port=$(start_server "$dir" accepted)
  stop_server "$(cat "$dir/server.pid")"
  prepare_retry_pr_hold "$dir" retry-task "$port"
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)
  [ -n "$request_id" ] || fail "held request record missing"
  jq -e 'select(.reason == "unavailable")' \
    "$dir/state/cipher-hooks/holds/$request_id.json" >/dev/null \
    || fail "trigger did not record the transient unavailable hold"

  # The gateway is still down: the sweep stays silent and the hold survives.
  out=$(FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" retry-held 2> "$dir/retry-down.err") \
    || fail "retry sweep failed while the gateway was still down"
  [ -z "$out" ] || fail "a still-unavailable gateway produced sweep output: $out"
  assert_present "$dir/state/cipher-hooks/holds/$request_id.json" \
    "silent sweep dropped the transient hold"

  # Gateway recovery on the same configured endpoint.
  start_server "$dir" accepted "$port" >/dev/null
  out=$(FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" retry-held 2> "$dir/retry-up.err") \
    || fail "retry sweep failed after gateway recovery"
  [ "$out" = "delivered $request_id iinvy-pr-ready retry-task" ] \
    || fail "recovered gateway did not report the delivered outcome: $out"
  jq -e --arg id "$request_id" \
    'select(.request_id == $id and .body.request_id == $id and .v2_valid and .timestamp_fresh and (.v1_present | not))' \
    "$dir/server.log" >/dev/null \
    || fail "retried delivery did not resend the exact recorded request with fresh HMAC V2"
  jq -e 'select(.http_status == 202)' "$dir/state/cipher-hooks/acks/$request_id.json" >/dev/null \
    || fail "retried delivery did not record its durable acknowledgement"
  assert_absent "$dir/state/cipher-hooks/holds/$request_id.json" "acknowledged retry left its hold behind"
  assert_absent "$dir/state/cipher-hooks/diagnostics/$request_id" "acknowledged retry left its diagnostic behind"

  # A second sweep after acknowledgement is silent and sends nothing.
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "recovery retry delivered $count times"
  out=$(FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" retry-held 2>/dev/null) || fail "post-acknowledgement sweep failed"
  [ -z "$out" ] || fail "acknowledged event re-entered the retry sweep: $out"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "acknowledged event was delivered again"
  ! grep -R -F "$SECRET" "$dir/state" "$dir/retry-down.err" "$dir/retry-up.err" >/dev/null \
    || fail "HMAC secret leaked into retry state or output"
  pass "a transiently held event is retried and acknowledged once after gateway recovery"
}

test_retry_supersedes_obsolete_holds() {
  local dir port request_id decision_id out
  dir=$(make_case supersede)
  : > "$dir/data/backlog.md"
  port=$(start_server "$dir" accepted)
  stop_server "$(cat "$dir/server.pid")"
  prepare_retry_pr_hold "$dir" stale-head-task "$port"
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)

  fm_write_meta "$dir/state/gone-task.meta" \
    "window=fm-gone-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship"
  printf 'needs-decision [key=net]: choose network\n' > "$dir/state/gone-task.status"
  cat >> "$dir/data/backlog.md" <<'EOF'
- [ ] gone-task - network https://github.com/example/project/issues/16 (kind: ship)
EOF
  set +e
  FM_CIPHER_RETRIES=1 FM_CIPHER_RETRY_DELAY_SECS=0 \
  FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" needs-decision gone-task net >/dev/null 2>&1
  set -e
  decision_id=$(request_id_for_kind "$dir" needs-decision)
  [ -n "$decision_id" ] || fail "held decision request record missing"

  # The PR head advanced while the gateway was down: a fresh exact-head event
  # owns the transition, so the old held event is durably superseded.
  perl -0pi -e "s/pr_head=$HEAD_A/pr_head=$HEAD_B/" "$dir/state/stale-head-task.meta"
  out=$(FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" retry-held 2>/dev/null) || fail "supersede sweep failed"
  case "$out" in
    *"superseded $request_id (identity-advanced)"*) ;;
    *) fail "advanced head hold was not superseded: $out" ;;
  esac
  jq -e 'select(.reason == "superseded-identity-advanced")' \
    "$dir/state/cipher-hooks/holds/$request_id.json" >/dev/null \
    || fail "advanced head hold did not record its superseded reason"

  # The decision was answered through the existing authority while held.
  case "$out" in
    *"superseded $decision_id"*) fail "an open held decision was superseded early" ;;
  esac
  printf 'resolved [key=net]: answered by captain\n' >> "$dir/state/gone-task.status"
  out=$(FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" retry-held 2>/dev/null) || fail "decision supersede sweep failed"
  [ "$out" = "superseded $decision_id (decision-closed)" ] \
    || fail "closed decision hold was not superseded: $out"
  jq -e 'select(.reason == "superseded-decision-closed")' \
    "$dir/state/cipher-hooks/holds/$decision_id.json" >/dev/null \
    || fail "closed decision hold did not record its superseded reason"

  # Superseded holds are non-transient: later sweeps stay silent and send nothing.
  out=$(FM_TEST_CREW_STATE='state: parked · source: run-step · parked at review' \
    run_hook "$dir" retry-held 2>/dev/null) || fail "post-supersede sweep failed"
  [ -z "$out" ] || fail "superseded holds re-entered the retry sweep: $out"
  [ ! -s "$dir/server.log" ] || fail "a superseded hold reached the gateway"

  # A retired task's records supersede a fresh transient hold too.
  prepare_retry_pr_hold "$dir" retired-task "$port"
  rm -f "$dir/state/retired-task.meta"
  out=$(FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" retry-held 2>/dev/null) || fail "retired-task sweep failed"
  case "$out" in
    *"superseded "*"(file-missing)"*) ;;
    *) fail "retired task hold was not superseded: $out" ;;
  esac
  pass "obsolete transient holds are durably superseded instead of retried"
}

test_watcher_retries_held_delivery() {
  local dir port request_id out wpid i
  dir=$(make_case watcher-retry)
  : > "$dir/data/backlog.md"
  port=$(start_server "$dir" accepted)
  stop_server "$(cat "$dir/server.pid")"
  prepare_retry_pr_hold "$dir" watch-task "$port"
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)
  start_server "$dir" accepted "$port" >/dev/null

  out="$dir/watch.out"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_CONFIG_OVERRIDE="$dir/config" \
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state" \
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
  FM_CIPHER_RETRIES=1 FM_CIPHER_RETRY_DELAY_SECS=0 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
  PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-watch.sh" > "$out" 2> "$dir/watch.err" &
  wpid=$!
  i=0
  while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$wpid" 2>/dev/null; then
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
    fail "watcher did not exit on the cipher retry wake"
  fi
  wait "$wpid" 2>/dev/null || true
  assert_grep "check: cipher-retry: delivered $request_id iinvy-pr-ready watch-task" "$out" \
    "watcher did not surface the delivered retry outcome"
  assert_grep "cipher-retry" "$dir/state/.wake-queue" \
    "watcher did not queue the durable cipher retry wake"
  assert_present "$dir/state/cipher-hooks/acks/$request_id.json" \
    "watcher retry did not record the durable acknowledgement"
  assert_absent "$dir/state/cipher-hooks/holds/$request_id.json" \
    "watcher retry left the transient hold behind"
  pass "normal supervision retries a held delivery after gateway recovery and wakes firstmate once"
}

test_reconcile_delivers_post_registration_green() {
  local dir port out rc request_id count head_c
  head_c='cccccccccccccccccccccccccccccccccccccccc'
  dir=$(make_case reconcile)
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] sync-task - close the reconciliation gap https://github.com/morris2spears/realvis-studio/issues/19 (kind: ship)
EOF
  run_repositories "$dir" add morris2spears/realvis-studio >/dev/null \
    || fail "RealVis registration for reconcile failed"
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled

  # Registration while the PR is behind or red records the PR, keeps waiting
  # for checks, and spends no Cipher event.
  set +e
  prepare_pr_case "$dir" sync-task morris2spears/realvis-studio "$HEAD_A" \
    'state: working · source: run-step · ci running' > "$dir/register.out" 2> "$dir/register.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "non-green RealVis registration should keep waiting for checks"
  assert_absent "$dir/state/cipher-hooks" "non-green registration emitted a Cipher event"

  # A reconcile sweep while the task is still not green stays silent.
  out=$(FM_TEST_HEAD=$HEAD_A FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
    run_hook "$dir" reconcile 2> "$dir/reconcile-red.err") || fail "not-green reconcile sweep failed"
  [ -z "$out" ] || fail "not-green reconcile produced output: $out"
  assert_absent "$dir/state/cipher-hooks" "not-green reconcile emitted a Cipher event"

  # A manual coordinator sync/rebase advances the head and checks reach green
  # outside the registration path. The sweep re-registers through the one
  # canonical trigger, refreshes the exact head, and delivers exactly once.
  out=$(FM_TEST_HEAD=$HEAD_B \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" reconcile 2> "$dir/reconcile-green.err") || fail "green reconcile sweep failed"
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)
  [ -n "$request_id" ] || fail "reconcile did not record the PR-ready request"
  [ "$out" = "delivered $request_id iinvy-pr-ready sync-task" ] \
    || fail "reconcile did not report the delivered outcome: $out"
  grep -qxF "pr_head=$HEAD_B" "$dir/state/sync-task.meta" \
    || fail "reconcile did not refresh the synced exact head in task metadata"
  jq -e --arg head "$HEAD_B" 'select(.body.pr_head_sha == $head and .v2_valid)' \
    "$dir/server.log" >/dev/null || fail "delivered event did not bind the synced exact head"
  assert_present "$dir/state/cipher-hooks/requests/$request_id.json" \
    "reconcile delivery did not record its durable request"
  assert_present "$dir/state/cipher-hooks/sent/$request_id.json" \
    "reconcile delivery did not record its delivery attempts"
  assert_present "$dir/state/cipher-hooks/acks/$request_id.json" \
    "reconcile delivery was not durably acknowledged"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "reconcile delivered $count times"

  # Duplicate reconciliation of the same green exact head is silent and does
  # not redeliver.
  out=$(FM_TEST_HEAD=$HEAD_B \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "duplicate reconcile sweep failed"
  [ -z "$out" ] || fail "duplicate reconcile redelivered: $out"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "duplicate reconcile reached the gateway"

  # An announcement is durable, not in-process. A sweep killed by the watcher's
  # check timeout after the acknowledgement landed leaves the announcement
  # owed; the next sweep still reports it rather than losing the wake forever,
  # and reports it without spending a second gateway delivery.
  rm -f "$dir/state/cipher-hooks/announced/$request_id"
  : > "$dir/state/cipher-hooks/announced/sync-task.pending"
  out=$(FM_TEST_HEAD=$HEAD_B \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "interrupted-announcement sweep failed"
  [ "$out" = "delivered $request_id iinvy-pr-ready sync-task" ] \
    || fail "an interrupted announcement was lost instead of reported: $out"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "recovered announcement reached the gateway again"
  assert_absent "$dir/state/cipher-hooks/announced/sync-task.pending" \
    "recovered announcement left its pending marker behind"

  # A further head advance while still green emits exactly one fresh
  # exact-head event under a new request identity.
  out=$(FM_TEST_HEAD=$head_c \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "advanced-head reconcile sweep failed"
  case "$out" in
    "delivered fmch-v1-"*" iinvy-pr-ready sync-task") ;;
    *) fail "advanced head reconcile did not deliver a fresh event: $out" ;;
  esac
  case "$out" in
    *"$request_id"*) fail "advanced head reused the earlier request identity" ;;
  esac
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 2 ] || fail "advanced head reconcile delivered $count total events"
  pass "reconcile delivers a post-registration checks-green transition once with the fresh exact head"
}

test_reconcile_hold_leaves_no_stale_announcement() {
  local dir port request_id out count
  dir=$(make_case reconcile-hold)
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] held-task - held reconciliation https://github.com/morris2spears/iinvy/issues/21 (kind: ship)
EOF
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  stop_server "$(cat "$dir/server.pid")"

  # Registration while the task is red spends no event even with the gateway
  # already down.
  set +e
  prepare_pr_case "$dir" held-task morris2spears/iinvy "$HEAD_A" \
    'state: working · source: run-step · ci running' >/dev/null 2>&1
  set -e
  assert_absent "$dir/state/cipher-hooks" "red registration emitted a Cipher event"

  # The sweep reaches green while the gateway is unavailable: the delivery
  # holds fail-closed, the sweep stays silent, and it owes no announcement.
  out=$(FM_TEST_HEAD=$HEAD_A FM_CIPHER_RETRIES=1 FM_CIPHER_RETRY_DELAY_SECS=0 \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "held reconcile sweep failed"
  [ -z "$out" ] || fail "a held reconcile delivery was announced: $out"
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)
  [ -n "$request_id" ] || fail "held reconcile did not record the PR-ready request"
  assert_present "$dir/state/cipher-hooks/holds/$request_id.json" \
    "held reconcile did not record its durable hold"
  assert_absent "$dir/state/cipher-hooks/announced/held-task.pending" \
    "a held reconcile iteration left a stale pending announcement"

  # A repeated sweep against the same held identity is silent and still owes
  # nothing, so the hold stays with retry-held.
  out=$(FM_TEST_HEAD=$HEAD_A \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "repeated held reconcile sweep failed"
  [ -z "$out" ] || fail "a repeated held reconcile sweep produced output: $out"
  assert_present "$dir/state/cipher-hooks/holds/$request_id.json" \
    "repeated held reconcile dropped the transient hold"
  assert_absent "$dir/state/cipher-hooks/announced/held-task.pending" \
    "a repeated held reconcile iteration left a stale pending announcement"

  # retry-held owns the recovery and reports the delivery once. The next
  # reconcile sweep must not announce that same acknowledgement again.
  start_server "$dir" accepted "$port" >/dev/null
  out=$(FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" retry-held 2>/dev/null) || fail "retry sweep failed after gateway recovery"
  [ "$out" = "delivered $request_id iinvy-pr-ready held-task" ] \
    || fail "recovered retry did not report the delivered outcome: $out"
  out=$(FM_TEST_HEAD=$HEAD_A \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "post-recovery reconcile sweep failed"
  [ -z "$out" ] || fail "reconcile re-announced a retry-held delivery: $out"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "post-recovery sweeps reached the gateway $count times"
  pass "a held reconcile delivery owes no announcement and is never re-announced after retry-held"
}

test_watcher_reconciles_post_registration_green() {
  local dir port request_id out wpid i
  dir=$(make_case watcher-reconcile)
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] recover-task - reconcile after recovery https://github.com/morris2spears/realvis-studio/issues/20 (kind: ship)
EOF
  run_repositories "$dir" add morris2spears/realvis-studio >/dev/null \
    || fail "RealVis registration for watcher reconcile failed"
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  # Register while red, then lose the observing session: only durable records
  # remain when the PR later reaches green.
  set +e
  prepare_pr_case "$dir" recover-task morris2spears/realvis-studio "$HEAD_A" \
    'state: working · source: run-step · ci running' >/dev/null 2>&1
  set -e
  assert_absent "$dir/state/cipher-hooks" "red registration emitted a Cipher event"

  out="$dir/watch.out"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_CONFIG_OVERRIDE="$dir/config" \
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state" \
  FM_TEST_HEAD=$HEAD_B \
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
  FM_CIPHER_RETRIES=1 FM_CIPHER_RETRY_DELAY_SECS=0 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
  PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-watch.sh" > "$out" 2> "$dir/watch.err" &
  wpid=$!
  i=0
  while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$wpid" 2>/dev/null; then
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
    fail "watcher did not exit on the cipher reconcile wake"
  fi
  wait "$wpid" 2>/dev/null || true
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)
  [ -n "$request_id" ] || fail "watcher reconcile did not record the PR-ready request"
  assert_grep "check: cipher-reconcile: delivered $request_id iinvy-pr-ready recover-task" "$out" \
    "watcher did not surface the reconciled delivery outcome"
  assert_grep "cipher-reconcile" "$dir/state/.wake-queue" \
    "watcher did not queue the durable cipher reconcile wake"
  assert_present "$dir/state/cipher-hooks/acks/$request_id.json" \
    "watcher reconcile did not record the durable acknowledgement"
  grep -qxF "pr_head=$HEAD_B" "$dir/state/recover-task.meta" \
    || fail "watcher reconcile did not refresh the green exact head"
  pass "normal supervision reconciles a post-registration checks-green transition and wakes firstmate once"
}

test_forge_green_overrides_wedged_local_monitor() {
  local dir port out rc request_id count
  dir=$(make_case forge-green)
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] wedged-task - transactionless entity https://github.com/morris2spears/iinvy/issues/292 (kind: ship)
- [ ] wedged-at-arm-task - same wedge at registration https://github.com/morris2spears/iinvy/issues/293 (kind: ship)
EOF
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled

  # Registration while neither the local pipeline nor GitHub is green: the
  # "armed:" line is a watch confirmation only, never a delivery.
  set +e
  prepare_pr_case "$dir" wedged-task morris2spears/iinvy "$HEAD_A" \
    'state: working · source: run-step · validating (running)' \
    > "$dir/register.out" 2> "$dir/register.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "not-yet-green registration should keep waiting for checks"
  assert_grep "armed: state/wedged-task.check.sh" "$dir/register.out" \
    "registration did not arm the merge poll"
  assert_absent "$dir/state/cipher-hooks" "an armed poll was mistaken for a delivery"

  # GitHub answers open and CLEAN for a pull request that has no check run of
  # its own - CI has not started, or the repository requires no checks. That is
  # mergeability, never proof that anything was verified, so the sweep must not
  # treat it as checks-green truth.
  out=$(FM_TEST_HEAD=$HEAD_A FM_TEST_FORGE_GREEN='OPEN CLEAN' \
    FM_TEST_CREW_STATE='state: working · source: run-step · validating (running)' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "checkless reconcile sweep failed"
  [ -z "$out" ] || fail "a pull request with no checks was reported delivered: $out"
  assert_absent "$dir/state/cipher-hooks" "a pull request with no checks spent a Cipher event"

  # A rollup whose only check is still running is equally not green.
  out=$(FM_TEST_HEAD=$HEAD_A FM_TEST_FORGE_GREEN='OPEN CLEAN' FM_TEST_FORGE_CHECKS=0 \
    FM_TEST_CREW_STATE='state: working · source: run-step · validating (running)' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "pending-check reconcile sweep failed"
  [ -z "$out" ] || fail "a pending check rollup was reported delivered: $out"
  assert_absent "$dir/state/cipher-hooks" "a pending check rollup spent a Cipher event"

  # GitHub reaches green/CLEAN while the pipeline's own CI monitor stays
  # silently wedged in a validating state: forge-side truth delivers anyway.
  out=$(FM_TEST_HEAD=$HEAD_A FM_TEST_FORGE_GREEN='OPEN CLEAN' FM_TEST_FORGE_CHECKS=1 \
    FM_TEST_CREW_STATE='state: working · source: run-step · validating (running)' \
    run_hook "$dir" reconcile 2> "$dir/reconcile.err") || fail "forge-green reconcile sweep failed"
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)
  [ -n "$request_id" ] || fail "forge-green reconcile did not record the PR-ready request"
  [ "$out" = "delivered $request_id iinvy-pr-ready wedged-task" ] \
    || fail "forge-green reconcile did not report the delivered outcome: $out"
  assert_present "$dir/state/cipher-hooks/acks/$request_id.json" \
    "forge-green delivery was not durably acknowledged"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "forge-green reconcile delivered $count times"

  # Repeating the sweep with the monitor still wedged does not redeliver.
  out=$(FM_TEST_HEAD=$HEAD_A FM_TEST_FORGE_GREEN='OPEN CLEAN' FM_TEST_FORGE_CHECKS=1 \
    FM_TEST_CREW_STATE='state: working · source: run-step · validating (running)' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "repeated forge-green sweep failed"
  [ -z "$out" ] || fail "repeated forge-green sweep redelivered: $out"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 1 ] || fail "repeated forge-green sweep reached the gateway"

  # When GitHub is already green at registration time, the registration-time
  # trigger itself delivers despite the wedged local monitor.
  set +e
  FM_TEST_FORGE_GREEN='OPEN CLEAN' FM_TEST_FORGE_CHECKS=1 \
    prepare_pr_case "$dir" wedged-at-arm-task morris2spears/iinvy "$HEAD_B" \
    'state: working · source: run-step · validating (running)' \
    > "$dir/register2.out" 2> "$dir/register2.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "forge-green registration should deliver and arm"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 2 ] || fail "forge-green registration delivered $count total events"
  jq -e --arg head "$HEAD_B" 'select(.body.pr_head_sha == $head and .body.task_id == "wedged-at-arm-task")' \
    "$dir/server.log" >/dev/null || fail "registration-time forge-green event did not bind its exact head"
  pass "GitHub-side green truth delivers the PR-ready event despite a wedged local CI monitor"
}

# The gh fake answers the snapshot query's own output shape, so the jq program
# that decides whether an unverified pull request may spend a merge-boundary
# event is exercised here directly, against real gh-shaped rollups.
test_forge_green_query_classifies_check_rollup() {
  local query verdict rollup expected line fields
  query=$(bash -uc '. "$1"; printf "%s" "$FM_PR_GITHUB_SNAPSHOT_QUERY"' _ "$ROOT/bin/fm-pr-lib.sh") \
    || fail "could not read the forge snapshot query"
  [ -n "$query" ] || fail "the forge snapshot query is empty"
  snapshot_line() { # <rollup-json>
    printf '{"state":"OPEN","mergeStateStatus":"CLEAN","headRefOid":"%s","statusCheckRollup":%s}' \
      "$HEAD_A" "$1" | jq -r "$query"
  }
  while IFS='|' read -r rollup expected; do
    [ -n "$rollup" ] || continue
    line=$(snapshot_line "$rollup") || fail "the snapshot query failed on rollup: $rollup"
    fields=$(printf '%s\n' "$line" | awk '{print NF}')
    [ "$fields" = 4 ] || fail "the snapshot query answered $fields fields for rollup $rollup: $line"
    verdict=$(printf '%s\n' "$line" | awk '{print $4}')
    [ "$verdict" = "$expected" ] \
      || fail "rollup $rollup answered green=$verdict, expected $expected"
  done <<'EOF'
null|0
[]|0
[{"__typename":"CheckRun","status":"QUEUED"}]|0
[{"__typename":"CheckRun","status":"IN_PROGRESS"}]|0
[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]|0
[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"}]|0
[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]|0
[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"NEUTRAL"}]|0
[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]|1
[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]|1
[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"IN_PROGRESS"}]|0
[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]|0
[{"__typename":"StatusContext","state":"SUCCESS"}]|1
[{"__typename":"StatusContext","state":"PENDING"}]|0
[{"__typename":"StatusContext","state":"FAILURE"}]|0
[{"__typename":"StatusContext","state":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]|1
EOF

  # Every column keeps its place when GitHub answers without a state, a
  # mergeability, or a head, so a caller never reads one field's value as
  # another's.
  line=$(printf '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}' | jq -r "$query") \
    || fail "the snapshot query failed on a field-less answer"
  fields=$(printf '%s\n' "$line" | awk '{print NF}')
  [ "$fields" = 4 ] || fail "a field-less answer collapsed to $fields fields: $line"
  [ "$(printf '%s\n' "$line" | awk '{print $4}')" = 1 ] \
    || fail "a field-less answer misplaced the green verdict: $line"
  pass "the forge snapshot query calls only a genuinely passed check rollup green"
}

test_reconcile_budget_reaches_every_gated_task_in_turn() {
  local dir port out id delivered count cursor sweep number
  dir=$(make_case reconcile-budget)
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] alpha-task - first gated pull request https://github.com/morris2spears/iinvy/issues/31 (kind: ship)
- [ ] bravo-task - second gated pull request https://github.com/morris2spears/iinvy/issues/32 (kind: ship)
- [ ] charlie-task - third gated pull request https://github.com/morris2spears/iinvy/issues/33 (kind: ship)
EOF
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled

  # Three gated pull requests, none green at registration, so no event is
  # spent before the sweeps run.
  number=31
  for id in alpha-task bravo-task charlie-task; do
    number=$((number + 1))
    fm_write_meta "$dir/state/$id.meta" \
      "window=fm-$id" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes"
    FM_TEST_HEAD=$HEAD_A \
    FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
      run_pr_check "$dir" "$id" "https://github.com/morris2spears/iinvy/pull/$number" \
      > "$dir/$id.register.out" 2> "$dir/$id.register.err" \
      || fail "registering $id failed"
  done
  assert_absent "$dir/state/cipher-hooks" "a not-green registration spent a Cipher event"

  # A budget of one task per cadence must still reach all three, one per
  # sweep, resuming after the task the previous sweep took.
  delivered=
  for sweep in 1 2 3; do
    out=$(FM_CIPHER_RECONCILE_BUDGET=1 FM_TEST_HEAD=$HEAD_A \
      FM_TEST_FORGE_GREEN='OPEN CLEAN' FM_TEST_FORGE_CHECKS=1 \
      FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
      run_hook "$dir" reconcile 2> "$dir/budget-$sweep.err") \
      || fail "budgeted reconcile sweep $sweep failed"
    count=$(printf '%s\n' "$out" | grep -c 'iinvy-pr-ready' || true)
    [ "$count" = 1 ] || fail "budgeted sweep $sweep delivered $count events: $out"
    id=${out##* }
    cursor=$(cat "$dir/state/.cipher-reconcile-cursor")
    [ "$cursor" = "$id" ] \
      || fail "budgeted sweep $sweep announced $id but resumes after $cursor"
    case " $delivered " in
      *" $id "*) fail "budgeted sweep $sweep repeated $id instead of advancing" ;;
    esac
    delivered="$delivered $id"
  done
  [ "$delivered" = " alpha-task bravo-task charlie-task" ] \
    || fail "budgeted sweeps did not reach every gated task in turn:$delivered"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 3 ] || fail "budgeted sweeps delivered $count events"

  # A fourth sweep wraps back to the first task, which is already acknowledged
  # and announced, so the wrap is silent and spends nothing.
  out=$(FM_CIPHER_RECONCILE_BUDGET=1 FM_TEST_HEAD=$HEAD_A \
    FM_TEST_FORGE_GREEN='OPEN CLEAN' FM_TEST_FORGE_CHECKS=1 \
    FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
    run_hook "$dir" reconcile 2>/dev/null) || fail "wrapped reconcile sweep failed"
  [ -z "$out" ] || fail "the wrapped sweep re-announced a delivered event: $out"
  [ "$(cat "$dir/state/.cipher-reconcile-cursor")" = alpha-task ] \
    || fail "the sweep did not wrap back to the first gated task"
  count=$(wc -l < "$dir/server.log" | tr -d ' ')
  [ "$count" = 3 ] || fail "the wrapped sweep reached the gateway"
  pass "a budgeted reconcile sweep reaches every gated task in turn across cadences"
}

test_repository_registration_store() {
  local dir other malformed duplicate concurrent rc i pid failed count port request_id
  local pids=
  dir=$(make_case repository-registration)
  other=$(make_case repository-registration-other-home)

  run_repositories "$dir" inspect --json | jq -e '
    .schema == "firstmate.cipher-repositories.v1"
    and .effective_source == "built-in-defaults"
    and .degraded == false
    and (.repositories | length == 5)
  ' >/dev/null || fail "default repository registration inspection was invalid"
  run_repositories "$dir" add Morris2Spears/RealVis-Studio > "$dir/add-first.out" \
    || fail "case-normalized repository add failed"
  run_repositories "$dir" add morris2spears/realvis-studio > "$dir/add-second.out" \
    || fail "idempotent repository add failed"
  assert_grep 'already registered: morris2spears/realvis-studio' "$dir/add-second.out" \
    "idempotent add did not report the effective registration"
  run_repositories "$dir" contains MORRIS2SPEARS/REALVIS-STUDIO \
    || fail "case-normalized registration was not effective"
  set +e
  run_repositories "$dir" add 'morris2spears/*' > /dev/null 2> "$dir/wildcard.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "wildcard registration must be rejected"
  assert_absent "$other/config/cipher-repositories.json" \
    "registration in one home modified another home"
  set +e
  run_repositories "$other" contains morris2spears/realvis-studio
  rc=$?
  set -e
  expect_code 1 "$rc" "a registration leaked into another home"

  rm -f "$dir/config/cipher-repositories.json"
  run_repositories "$dir" contains morris2spears/realvis-studio \
    || fail "a missing primary did not retain the last-known-good registration"
  run_repositories "$dir" inspect --json | jq -e '
    .effective_source == "last-known-good" and .degraded == true
  ' >/dev/null || fail "missing-primary recovery was not reported clearly"
  printf '{broken\n' > "$dir/config/cipher-repositories.json"
  chmod 0600 "$dir/config/cipher-repositories.json"
  run_repositories "$dir" contains morris2spears/realvis-studio \
    || fail "a corrupt primary did not retain the last-known-good registration"
  printf '{also-broken\n' > "$dir/config/cipher-repositories.last-good.json"
  chmod 0600 "$dir/config/cipher-repositories.last-good.json"
  set +e
  run_repositories "$dir" validate > /dev/null 2> "$dir/corrupt.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "corrupt primary and fallback must refuse registration resolution"
  : > "$dir/gh-axi.log"
  fm_write_meta "$dir/state/corrupt-task.meta" \
    "window=fm-corrupt-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" \
    "pr=https://github.com/morris2spears/realvis-studio/pull/19"
  set +e
  run_pr_merge "$dir" corrupt-task https://github.com/morris2spears/realvis-studio/pull/19 \
    > "$dir/corrupt-merge.out" 2> "$dir/corrupt-merge.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unavailable registration source must hold merge"
  assert_no_grep 'pr merge' "$dir/gh-axi.log" "unavailable registration source reached merge"

  malformed=$(make_case repository-registration-malformed)
  printf '%s\n' '{"schema":"firstmate.cipher-repositories.v2","repositories":["morris2spears/iinvy"]}' \
    > "$malformed/config/cipher-repositories.json"
  chmod 0600 "$malformed/config/cipher-repositories.json"
  set +e
  run_repositories "$malformed" validate > /dev/null 2> "$malformed/validate.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "unsupported registration schema must be rejected"

  duplicate=$(make_case repository-registration-duplicate)
  printf '%s\n' '{"schema":"firstmate.cipher-repositories.v1","repositories":["morris2spears/iinvy","morris2spears/iinvy"]}' \
    > "$duplicate/config/cipher-repositories.json"
  chmod 0600 "$duplicate/config/cipher-repositories.json"
  set +e
  run_repositories "$duplicate" validate > /dev/null 2> "$duplicate/validate.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "duplicate registration entries must be rejected"

  concurrent=$(make_case repository-registration-concurrent)
  failed=0
  for i in $(seq 1 20); do
    run_repositories "$concurrent" add "example/repo-$i" \
      > "$concurrent/add-$i.out" 2> "$concurrent/add-$i.err" &
    pids="$pids $!"
  done
  for i in $(seq 1 20); do
    run_repositories "$concurrent" inspect --json | jq -e '.schema == "firstmate.cipher-repositories.v1"' \
      >/dev/null || failed=1
  done
  for pid in $pids; do
    wait "$pid" || failed=1
  done
  [ "$failed" -eq 0 ] || fail "a concurrent registration read or write failed"
  count=$(run_repositories "$concurrent" list | wc -l | tr -d ' ')
  [ "$count" = 25 ] || fail "concurrent adds lost registrations: $count effective entries"

  dir=$(make_case repository-registration-removal)
  run_repositories "$dir" add morris2spears/realvis-studio >/dev/null \
    || fail "removal fixture registration failed"
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  prepare_pr_case "$dir" realvis-task morris2spears/realvis-studio \
    > "$dir/realvis.out" 2> "$dir/realvis.err" \
    || fail "in-flight RealVis request fixture failed"
  request_id=$(request_id_for_kind "$dir" iinvy-pr-ready)
  [ -n "$request_id" ] || fail "in-flight RealVis request was not recorded"
  stop_server "$(cat "$dir/server.pid")"
  set +e
  run_repositories "$dir" remove morris2spears/realvis-studio \
    > /dev/null 2> "$dir/remove-inflight.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "removal with in-flight gated work must refuse"
  run_repositories "$dir" contains morris2spears/realvis-studio \
    || fail "refused removal released in-flight gated work"
  rm -f "$dir/state/realvis-task.meta"
  run_repositories "$dir" remove morris2spears/realvis-studio > "$dir/remove.out" \
    || fail "safe repository removal failed"
  set +e
  run_repositories "$dir" contains morris2spears/realvis-studio
  rc=$?
  set -e
  expect_code 1 "$rc" "removed repository remained enrolled"
  printf '{broken-after-remove\n' > "$dir/config/cipher-repositories.json"
  chmod 0600 "$dir/config/cipher-repositories.json"
  run_repositories "$dir" contains morris2spears/realvis-studio \
    || fail "degraded recovery released a recently removed registration"
  run_repositories "$dir" rollback > "$dir/rollback.out" || fail "registration rollback failed"
  run_repositories "$dir" contains morris2spears/realvis-studio \
    || fail "rollback did not restore the prior registration"
  pass "repository registrations are per-home, validated, atomic, recoverable, and removal-safe"
}

test_removal_waits_for_wrapped_pr_check_publication() {
  local dir repo id real_mv paused released check_pid remove_pid rc ck i port
  dir=$(make_case removal-race)
  repo=morris2spears/racecheck
  run_repositories "$dir" add "$repo" >/dev/null || fail "race fixture registration failed"
  port=$(start_server "$dir" accepted)
  write_config "$dir" "$port" enabled enabled
  id=race-task
  fm_write_meta "$dir/state/$id.meta" \
    "window=fm-$id" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes"

  real_mv=$(command -v mv)
  paused="$dir/mv-paused"
  released="$dir/mv-release"
  cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
last=\${!#}
if [ "\$last" = "$dir/state/$id.meta" ]; then
  : > "$paused"
  i=0
  while [ ! -e "$released" ] && [ "\$i" -lt 300 ]; do
    sleep 0.1
    i=\$((i + 1))
  done
fi
exec "$real_mv" "\$@"
SH
  chmod +x "$dir/fakebin/mv"

  : > "$dir/gh-axi.log"
  FM_TEST_HEAD=$HEAD_A \
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green: PR ready for review' \
    run_pr_check "$dir" "$id" "https://github.com/$repo/pull/19" \
    > "$dir/check.out" 2> "$dir/check.err" &
  check_pid=$!

  i=0
  while [ ! -e "$paused" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$paused" ] || fail "wrapped PR-check never reached metadata publication under the shared lock"

  run_repositories "$dir" remove "$repo" > "$dir/remove-blocked.out" 2> "$dir/remove-blocked.err" &
  remove_pid=$!
  i=0
  while kill -0 "$remove_pid" 2>/dev/null && [ "$i" -lt 10 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$remove_pid" 2>/dev/null \
    || fail "removal acquired exclusivity while the wrapped PR-check still held the shared lock"

  : > "$released"
  ck=0
  wait "$check_pid" || ck=$?
  expect_code 0 "$ck" "wrapped PR-check did not complete after the pause was released"
  rc=0
  wait "$remove_pid" || rc=$?
  expect_code 2 "$rc" "removal did not refuse once matching PR metadata became visible"
  assert_grep "in-flight gated work" "$dir/remove-blocked.err" \
    "removal refusal did not cite the newly published in-flight task"
  assert_grep "pr=https://github.com/$repo/pull/19" "$dir/state/$id.meta" \
    "PR-check did not publish metadata once the shared lock was released"
  run_repositories "$dir" contains "$repo" \
    || fail "a removal racing publication released in-flight gated work"
  pass "an exclusive removal cannot enter until a wrapped PR-check's publication and classification complete"
}

test_recorded_head_survives_a_silent_forge() {
  local dir head
  dir=$(make_case head-preservation)
  cat > "$dir/data/backlog.md" <<'EOF'
- [ ] silent-forge-task - head preservation https://github.com/morris2spears/iinvy/issues/34 (kind: ship)
EOF
  fm_write_meta "$dir/state/silent-forge-task.meta" \
    "window=fm-silent-forge-task" "worktree=$dir/wt" "project=$dir/wt" "kind=ship" "mode=no-mistakes"
  FM_TEST_HEAD=$HEAD_A FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
    run_pr_check "$dir" silent-forge-task https://github.com/morris2spears/iinvy/pull/34 \
    > "$dir/register.out" 2> "$dir/register.err" || fail "registration failed"
  head=$(grep '^pr_head=' "$dir/state/silent-forge-task.meta" | cut -d= -f2-)
  [ "$head" = "$HEAD_A" ] || fail "registration did not record the exact head: $head"

  # Re-registering the same pull request while the forge cannot answer is
  # head-unknown, never head-changed, so the recorded exact head survives.
  FM_TEST_GH_FAIL=1 FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
    run_pr_check "$dir" silent-forge-task https://github.com/morris2spears/iinvy/pull/34 \
    > "$dir/silent.out" 2> "$dir/silent.err" || fail "re-registration under a silent forge failed"
  head=$(grep '^pr_head=' "$dir/state/silent-forge-task.meta" | cut -d= -f2-)
  [ "$head" = "$HEAD_A" ] || fail "a silent forge erased or changed the recorded head: $head"

  # Registering a different pull request while the forge is silent records no
  # head at all: the recorded one belongs to the previous pull request.
  FM_TEST_GH_FAIL=1 FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
    run_pr_check "$dir" silent-forge-task https://github.com/morris2spears/iinvy/pull/35 \
    > "$dir/replaced.out" 2> "$dir/replaced.err" || fail "replacement registration failed"
  grep -q '^pr_head=' "$dir/state/silent-forge-task.meta" \
    && fail "a replaced pull request inherited the previous pull request's head"
  grep -qxF 'pr=https://github.com/morris2spears/iinvy/pull/35' "$dir/state/silent-forge-task.meta" \
    || fail "the replacement pull request was not recorded"

  # Once the forge answers again the head is refreshed from it.
  FM_TEST_HEAD=$HEAD_B FM_TEST_CREW_STATE='state: working · source: run-step · ci running' \
    run_pr_check "$dir" silent-forge-task https://github.com/morris2spears/iinvy/pull/35 \
    > "$dir/recovered.out" 2> "$dir/recovered.err" || fail "recovered registration failed"
  head=$(grep '^pr_head=' "$dir/state/silent-forge-task.meta" | cut -d= -f2-)
  [ "$head" = "$HEAD_B" ] || fail "a recovered forge did not refresh the head: $head"
  pass "a silent forge preserves the recorded exact head only for the same pull request"
}

test_forge_green_query_classifies_check_rollup
test_repository_registration_store
test_removal_waits_for_wrapped_pr_check_publication
test_reconcile_budget_reaches_every_gated_task_in_turn
test_recorded_head_survives_a_silent_forge
test_v2_decision_and_pr_delivery_dedupe
test_note_keyed_decision_single_hook_and_park
test_resolve_decision_requires_and_follows_authenticated_answer
test_legacy_v1_is_explicit_test_only
test_real_duplicate_response_is_accepted_exactly
test_malformed_and_unavailable_hold_without_leakage
test_timeout_is_durable_hold
test_legacy_socket_timeout_is_classified_as_timeout
test_pr_check_allowlist_and_safe_holds
test_iinvy_merge_requires_cipher_actor_and_exact_head
test_receive_api_ignores_self_repo_worker_pane
test_retry_held_after_gateway_recovery
test_retry_supersedes_obsolete_holds
test_watcher_retries_held_delivery
test_reconcile_delivers_post_registration_green
test_reconcile_hold_leaves_no_stale_announcement
test_watcher_reconciles_post_registration_green
test_forge_green_overrides_wedged_local_monitor
