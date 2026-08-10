#!/usr/bin/env bash
# Behavior tests for the captain-attention nudge (bin/fm-decision-nudge.sh).
#
# The hook payloads used here are byte-shaped from live Claude Code 2.1.226
# captures (docs/verification/decision-nudge.md): a waiting AskUserQuestion and
# a waiting permission dialog both emit a Notification event with
# notification_type=permission_prompt. This suite drives the arm/wait/disarm
# contract without spawning a harness; the live-capture evidence stays in the
# verification record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NUDGE="$ROOT/bin/fm-decision-nudge.sh"
TMP=$(fm_test_tmproot fm-decision-nudge)

# A primary-shaped home: plain checkout (git-dir == git-common-dir) carrying
# AGENTS.md, bin/, state/, and the Telegram-mode opt-in flag.
FIX="$TMP/primary"
mkdir -p "$FIX/bin" "$FIX/state" "$FIX/config"
fm_git_identity
git -C "$FIX" init -q
touch "$FIX/AGENTS.md"
git -C "$FIX" add AGENTS.md
git -C "$FIX" commit -qm initial
touch "$FIX/config/telegram-mode"

SENT="$TMP/tg-sent.log"
cat > "$TMP/tg-capture" <<SH
#!/usr/bin/env bash
cat >> '$SENT'
SH
chmod +x "$TMP/tg-capture"

export FM_ROOT_OVERRIDE="$FIX" FM_HOME="$FIX" FMTG_TG_BIN="$TMP/tg-capture"
export FM_DECISION_NUDGE_DELAY_SECS=1
MARKER="$FIX/state/.decision-nudge-pending"

payload() {  # <prompt-id> [notification-type]
  printf '{"session_id":"sess-1","prompt_id":"%s","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"%s"}' \
    "$1" "${2:-permission_prompt}"
}

# --- unanswered prompt sends exactly one content-free nudge ------------------

payload p1 | "$NUDGE" --claude-pending || fail "arm exited nonzero"
[ -f "$MARKER" ] || fail "arm did not record the pending prompt"
assert_contains "$(cat "$MARKER")" "status=pending" "marker status"
sleep 2.5
[ "$(cat "$SENT" 2>/dev/null)" = "Captain, something's awaiting your attention." ] \
  || fail "expected exactly the content-free nudge, got: $(cat "$SENT" 2>/dev/null)"
assert_contains "$(cat "$MARKER")" "status=sent" "sent marker after nudge"
pass "unanswered prompt sends one content-free nudge after the delay"

# --- repeat notification for the same turn never re-arms ---------------------

payload p1 | "$NUDGE" --claude-pending || fail "repeat arm exited nonzero"
sleep 2.5
[ "$(grep -c Captain "$SENT")" = 1 ] || fail "repeat notification for the same turn re-sent the nudge"
pass "repeat notification for the same turn stays a single nudge"

# --- disarm clears the record ------------------------------------------------

"$NUDGE" --claude-resolved || fail "resolved exited nonzero"
[ ! -e "$MARKER" ] || fail "resolved left the marker behind"
pass "resolved removes the pending record"

# --- an answer inside the delay suppresses the nudge -------------------------

: > "$SENT"
payload p2 | "$NUDGE" --claude-pending
"$NUDGE" --claude-resolved
sleep 2.5
[ ! -s "$SENT" ] || fail "a promptly answered question still nudged: $(cat "$SENT")"
[ ! -e "$MARKER" ] || fail "answered path left a marker"
pass "a prompt answered inside the delay never nudges"

# --- a fresh turn after a sent nudge arms again ------------------------------

: > "$SENT"
payload p3 | "$NUDGE" --claude-pending
sleep 2.5
[ "$(grep -c Captain "$SENT")" = 1 ] || fail "fresh turn did not arm after a prior sent nudge"
"$NUDGE" --claude-resolved
pass "a fresh turn arms independently of the prior sent record"

# --- without the Telegram opt-in the feature is inert ------------------------

rm -f "$FIX/config/telegram-mode"
: > "$SENT"
payload p4 | "$NUDGE" --claude-pending
[ ! -e "$MARKER" ] || fail "armed without the Telegram-mode opt-in"
sleep 2.5
[ ! -s "$SENT" ] || fail "sent without the Telegram-mode opt-in"
touch "$FIX/config/telegram-mode"
pass "no Telegram opt-in means no marker and no send"

# --- a linked task worktree never arms ---------------------------------------

WT="$TMP/task-worktree"
git -C "$FIX" worktree add -q "$WT" -b fm-test-wt
mkdir -p "$WT/bin" "$WT/state" "$WT/config"
touch "$WT/config/telegram-mode"
payload p5 | FM_ROOT_OVERRIDE="$WT" FM_HOME="$WT" "$NUDGE" --claude-pending
[ ! -e "$WT/state/.decision-nudge-pending" ] || fail "a linked task worktree armed the nudge"
pass "linked task worktrees stay out of scope"

# --- non-permission notification types are ignored ---------------------------

payload p6 idle | "$NUDGE" --claude-pending
[ ! -e "$MARKER" ] || fail "a non-permission notification type armed the nudge"
pass "only permission_prompt notifications arm"

# --- a stale timer nonce never fires after a newer arm -----------------------

: > "$SENT"
payload p7 | "$NUDGE" --claude-pending
OLD_NONCE=$(sed -n 's/^nonce=//p' "$MARKER")
"$NUDGE" --claude-resolved
payload p8 | "$NUDGE" --claude-pending
"$NUDGE" --wait "$OLD_NONCE" &
wait $! 2>/dev/null || true
[ "$(sed -n 's/^prompt_id=//p' "$MARKER" 2>/dev/null)" = p8 ] || fail "stale timer disturbed the newer arm"
"$NUDGE" --claude-resolved
pass "a stale timer nonce cannot fire against a newer arm"

# --- hook registration contract ----------------------------------------------

SETTINGS="$ROOT/.claude/settings.json"
command -v jq >/dev/null 2>&1 || fail "jq required for the registration assertions"
jq -e '.hooks.Notification[] | select(.matcher == "permission_prompt") | .hooks[]
       | select(.command | test("fm-decision-nudge\\.sh --claude-pending"))' \
  "$SETTINGS" >/dev/null || fail "Notification permission_prompt arm hook not registered"
jq -e '.hooks.PostToolUse[] | select(.matcher == ".*") | .hooks[]
       | select(.command | test("fm-decision-nudge\\.sh --claude-resolved"))' \
  "$SETTINGS" >/dev/null || fail "PostToolUse disarm hook not registered"
jq -e '.hooks.UserPromptSubmit[].hooks[]
       | select(.command | test("fm-decision-nudge\\.sh --claude-resolved"))' \
  "$SETTINGS" >/dev/null || fail "UserPromptSubmit disarm hook not registered"
jq -e '.hooks.Stop[].hooks[]
       | select(.command | test("fm-decision-nudge\\.sh --claude-resolved"))' \
  "$SETTINGS" >/dev/null || fail "Stop disarm hook not registered"
pass "tracked settings register the arm and every disarm hook"

printf 'ok - fm-decision-nudge behavior suite complete\n'
