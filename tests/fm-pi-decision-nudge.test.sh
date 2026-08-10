#!/usr/bin/env bash
# Behavior tests for the Pi primary captain-attention extension and the shared
# decision-nudge marker/timer transport.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NUDGE="$ROOT/bin/fm-decision-nudge.sh"
EXT="$ROOT/.pi/extensions/fm-primary-decision-nudge.ts"
TMP=$(fm_test_tmproot fm-pi-decision-nudge)
FIX="$TMP/primary"
SENT="$TMP/tg-sent.log"
MARKER="$FIX/state/.decision-nudge-pending"
export NODE_NO_WARNINGS=1

mkdir -p "$FIX/bin" "$FIX/state" "$FIX/config"
fm_git_identity
git -C "$FIX" init -q
touch "$FIX/AGENTS.md"
git -C "$FIX" add AGENTS.md
git -C "$FIX" commit -qm initial
touch "$FIX/config/telegram-mode"

cat > "$TMP/tg-capture" <<SH
#!/usr/bin/env bash
cat >> '$SENT'
SH
chmod +x "$TMP/tg-capture"

export FM_ROOT_OVERRIDE="$FIX" FM_HOME="$FIX" FM_STATE_OVERRIDE="$FIX/state"
export FM_CONFIG_OVERRIDE="$FIX/config" FMTG_TG_BIN="$TMP/tg-capture"
export FM_DECISION_NUDGE_DELAY_SECS=1

wait_for_file() {  # <path>
  local path=$1 i=0
  while [ "$i" -lt 40 ]; do
    [ -e "$path" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_status() {  # <status>
  local expected=$1 i=0
  while [ "$i" -lt 60 ]; do
    [ "$(sed -n 's/^status=//p' "$MARKER" 2>/dev/null)" = "$expected" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- heuristic ---------------------------------------------------------------

PLUGIN="$EXT" node --input-type=module <<'JS' || fail "Pi wait heuristic assertions failed"
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const yes = [
  "Captain, should I merge this?",
  "Captain, I need your decision: choose A or B.",
  "Captain, options: keep the old behavior or use the new behavior.",
  "Captain, please approve the deploy plan before I continue.",
  "Captain, choose the branch you want me to land this on.",
];
for (const text of yes) {
  if (!mod.isCaptainAttentionWait(text)) throw new Error(`expected arm: ${text}`);
}
const no = [
  "Captain, shipshape.",
  "Captain, the review is complete.",
  "Should I continue?",
  "",
  "Captain, PR #7 is merged and CI is green. I'll confirm the deploy once you're back.",
  "Captain, the watcher cycle is healthy and I'll pick the next task from the queue.",
  "Captain, I approved the crewmate's plan and landed it on main.",
];
for (const text of no) {
  if (mod.isCaptainAttentionWait(text)) throw new Error(`unexpected arm: ${text}`);
}
const ctx = {
  sessionManager: {
    getBranch() {
      return [
        { type: "message", id: "user1", message: { role: "user", content: "go" } },
        { type: "message", id: "assistant1", message: { role: "assistant", content: [
          { type: "thinking", thinking: "private" },
          { type: "text", text: "Captain, approve option A?" },
        ] } },
      ];
    },
  },
};
const wait = mod.latestCaptainAttentionWait(ctx);
if (wait?.id !== "assistant1" || wait.text !== "Captain, approve option A?") {
  throw new Error(`latest assistant wait not found: ${JSON.stringify(wait)}`);
}
const branchCtx = (entries) => ({ sessionManager: { getBranch: () => entries } });
const toolNoise = mod.latestCaptainAttentionWait(branchCtx([
  { type: "message", id: "user1", message: { role: "user", content: "go" } },
  { type: "message", id: "assistant1", message: { role: "assistant", content: [{ type: "text", text: "Captain, approve option A?" }] } },
  { type: "message", id: "assistant2", message: { role: "assistant", content: [{ type: "tool_use", id: "t1" }] } },
]));
if (toolNoise?.id !== "assistant1") {
  throw new Error(`tool-only trailing entry hid the latest non-empty ask: ${JSON.stringify(toolNoise)}`);
}
const answered = mod.latestCaptainAttentionWait(branchCtx([
  { type: "message", id: "assistant1", message: { role: "assistant", content: [{ type: "text", text: "Captain, approve option A?" }] } },
  { type: "message", id: "user2", message: { role: "user", content: "yes" } },
]));
if (answered !== null) {
  throw new Error(`scan crossed the turn boundary: ${JSON.stringify(answered)}`);
}
JS
pass "Pi heuristic arms only explicit captain-facing waits"

# --- extension event wiring --------------------------------------------------

cp "$NUDGE" "$FIX/bin/fm-decision-nudge.sh"
cp "$ROOT/bin/fm-primary-scope-lib.sh" "$FIX/bin/fm-primary-scope-lib.sh"
cp "$ROOT/bin/fm-tg-lib.sh" "$FIX/bin/fm-tg-lib.sh"
cp "$ROOT/bin/fm-x-lib.sh" "$FIX/bin/fm-x-lib.sh"
chmod +x "$FIX/bin/fm-decision-nudge.sh"

PLUGIN="$EXT" node --input-type=module <<'JS' || fail "Pi extension event wiring failed"
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = {
  on(name, handler) {
    handlers.set(name, handler);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
for (const name of ["input", "before_agent_start", "agent_settled", "session_shutdown"]) {
  if (!handlers.has(name)) throw new Error(`missing ${name} handler`);
}
const context = (id, text) => ({
  sessionManager: {
    getBranch() {
      return [{ type: "message", id, message: { role: "assistant", content: [{ type: "text", text }] } }];
    },
  },
});
handlers.get("agent_settled")({}, context("ask1", "Captain, should I continue?"));
const marker = `${process.env.FM_STATE_OVERRIDE}/.decision-nudge-pending`;
for (let i = 0; i < 50 && !existsSync(marker); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(marker)) throw new Error("settled captain question did not arm");
handlers.get("input")({ source: "interactive" });
for (let i = 0; i < 50 && existsSync(marker); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (existsSync(marker)) throw new Error("interactive captain input did not disarm");
handlers.get("agent_settled")({}, context("ask2", "Captain, choose option A or B."));
for (let i = 0; i < 50 && !existsSync(marker); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(marker)) throw new Error("second settled captain question did not arm");
handlers.get("before_agent_start")({});
for (let i = 0; i < 50 && existsSync(marker); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (existsSync(marker)) throw new Error("before_agent_start did not disarm");
handlers.get("agent_settled")({}, context("idle1", "Captain, shipshape."));
await new Promise((resolve) => setTimeout(resolve, 100));
if (existsSync(marker)) throw new Error("routine shipshape reply armed");
handlers.get("agent_settled")({}, context("noise1", ""));
await new Promise((resolve) => setTimeout(resolve, 100));
if (existsSync(marker)) throw new Error("empty assistant turn armed");
JS
pass "Pi agent_settled arms chat waits and captain presence disarms"

# --- marker, timer, claim, and duplicate suppression -------------------------

"$NUDGE" --pi-arm wait-one || fail "Pi arm exited nonzero"
wait_for_file "$MARKER" || fail "Pi arm did not create the pending marker"
assert_contains "$(cat "$MARKER")" "prompt_id=pi:wait-one" "Pi marker prompt identity"
assert_contains "$(cat "$MARKER")" "status=pending" "Pi marker pending state"
"$NUDGE" --pi-resolved || fail "Pi resolve exited nonzero"
[ ! -e "$MARKER" ] || fail "Pi resolve left the marker behind"
pass "Pi arm and resolve own one pending marker"

: > "$SENT"
"$NUDGE" --pi-arm wait-two || fail "timer arm exited nonzero"
wait_for_status sent || fail "timer did not claim and mark the wait sent"
[ "$(cat "$SENT")" = "Captain, something's awaiting your attention." ] \
  || fail "timer did not send exactly the content-free message: $(cat "$SENT" 2>/dev/null)"
"$NUDGE" --pi-arm wait-two || fail "duplicate arm exited nonzero"
sleep 1.5
[ "$(grep -c Captain "$SENT")" = 1 ] || fail "same wait sent more than one nudge"
"$NUDGE" --pi-resolved
pass "detached timer claims once and suppresses duplicate sends"

: > "$SENT"
"$NUDGE" --pi-arm wait-three
"$NUDGE" --pi-resolved
sleep 1.5
[ ! -s "$SENT" ] || fail "resolved wait still sent a nudge"
pass "a captain answer inside the delay cancels the send"

# --- consent and scope -------------------------------------------------------

rm -f "$FIX/config/telegram-mode"
"$NUDGE" --pi-arm no-optin
sleep 0.2
[ ! -e "$MARKER" ] || fail "missing Telegram opt-in still armed"
[ ! -s "$SENT" ] || fail "missing Telegram opt-in still sent"
touch "$FIX/config/telegram-mode"
pass "missing Telegram opt-in is inert"

WT="$TMP/task-worktree"
git -C "$FIX" worktree add -q "$WT" -b fm-pi-nudge-linked-test
mkdir -p "$WT/state" "$WT/config"
touch "$WT/config/telegram-mode"
FM_ROOT_OVERRIDE="$WT" FM_HOME="$WT" FM_STATE_OVERRIDE="$WT/state" \
  FM_CONFIG_OVERRIDE="$WT/config" "$NUDGE" --pi-arm linked-task
sleep 0.2
[ ! -e "$WT/state/.decision-nudge-pending" ] || fail "linked task worktree armed the nudge"
pass "non-primary linked worktrees stay out of scope"

FM_DECISION_NUDGE_DELAY_SECS=10 "$NUDGE" --pi-arm scope-disarm \
  || fail "primary arm before the crew disarm probe failed"
wait_for_file "$MARKER" || fail "primary arm did not create the pending marker"
FM_ROOT_OVERRIDE="$WT" FM_HOME="$FIX" FM_STATE_OVERRIDE="$FIX/state" \
  FM_CONFIG_OVERRIDE="$FIX/config" "$NUDGE" --pi-resolved
[ -e "$MARKER" ] || fail "a crew worktree cancelled the captain's armed nudge"
"$NUDGE" --pi-resolved || fail "primary resolve exited nonzero"
[ ! -e "$MARKER" ] || fail "primary resolve left the marker behind"
pass "only a primary session can disarm the captain's pending nudge"

printf 'ok - Pi captain-attention decision-nudge suite complete\n'
