#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the captain-attention nudge
# (bin/fm-decision-nudge.sh + the tracked .claude/settings.json registration).
# Proves, against the real installed Claude Code and the real tracked hooks:
# a waiting AskUserQuestion arms the pending record through the Notification
# permission_prompt hook without delaying the interactive prompt; an unanswered
# question sends exactly one content-free Telegram nudge through the captured
# client after the configured delay; and a question answered inside the delay
# sends nothing and clears the record through the PostToolUse disarm.
# The project and home are isolated clones; Claude keeps using its existing
# managed authentication and the interactive session runs in a private tmux
# session. No live fleet home, worktree, or session is touched, and no real
# Telegram message is sent (FMTG_TG_BIN is a capture stub).
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude decision-nudge live regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux capture-pane -t "$TMUX_SESSION" -p | tail -20 >&2 || true
  fi
  exit 1
}

command -v claude >/dev/null 2>&1 || { echo "skip: claude not found"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
CLAUDE_VERSION=$(claude --version)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-decision-nudge-e2e.XXXXXX")
PROJECT="$LAB/project"
TMUX_SESSION="fm-nudge-e2e-$$"

cleanup() {
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the auto-arm live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The session-open nudge would steer the model toward fm-session-start.sh;
# this regression drives AskUserQuestion directly, so neutralize just that.
printf '#!/usr/bin/env bash\nexit 0\n' > "$PROJECT/bin/fm-sessionstart-nudge.sh"
chmod +x "$PROJECT/bin/fm-sessionstart-nudge.sh"

mkdir -p "$PROJECT/state" "$PROJECT/config"
touch "$PROJECT/config/telegram-mode"
SENT="$LAB/tg-sent.log"
cat > "$LAB/tg-capture" <<SH
#!/usr/bin/env bash
cat >> '$SENT'
SH
chmod +x "$LAB/tg-capture"

MARKER="$PROJECT/state/.decision-nudge-pending"
DELAY=8

wait_for() {  # <seconds> <description> <check-command...>
  local deadline=$1 desc=$2 i=0
  shift 2
  while [ "$i" -lt $((deadline * 2)) ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  fail "timed out waiting for $desc"
}

marker_status_is() {
  [ "$(sed -n 's/^status=//p' "$MARKER" 2>/dev/null)" = "$1" ]
}

pane_shows_question() {
  tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null | grep -q 'Enter to select'
}

tmux new-session -d -s "$TMUX_SESSION" -c "$PROJECT" -x 200 -y 50
tmux send-keys -t "$TMUX_SESSION" -l "FM_HOME='$PROJECT' FMTG_TG_BIN='$LAB/tg-capture' FM_DECISION_NUDGE_DELAY_SECS=$DELAY claude --model haiku --permission-mode default"
tmux send-keys -t "$TMUX_SESSION" Enter

# First launch in a fresh directory shows the workspace-trust dialog. The ❯
# glyph appears inside that dialog too, so readiness means the dialog is gone
# AND the ready status line is on screen, plus a settle beat for the editor.
wait_for 30 "the workspace trust dialog" \
  bash -c "tmux capture-pane -t '$TMUX_SESSION' -p | grep -q 'trust this folder'"
tmux send-keys -t "$TMUX_SESSION" Enter
wait_for 30 "the ready input editor after trust" \
  bash -c "tmux capture-pane -t '$TMUX_SESSION' -p | grep -qv 'trust this folder' && tmux capture-pane -t '$TMUX_SESSION' -p | grep -q 'for agents'"
sleep 2

# send_prompt <text>: type into the editor, confirm the text landed (retyping
# once if a UI transition swallowed it), then submit.
send_prompt() {
  local text=$1 attempt
  for attempt in 1 2; do
    tmux send-keys -t "$TMUX_SESSION" -l "$text"
    sleep 1
    if tmux capture-pane -t "$TMUX_SESSION" -p | grep -qF "${text:0:40}"; then
      tmux send-keys -t "$TMUX_SESSION" Enter
      return 0
    fi
    [ "$attempt" = 1 ] && sleep 2
  done
  fail "the prompt text never appeared in the input editor"
}

# --- scenario 1: unanswered question nudges exactly once ---------------------

send_prompt 'Use the AskUserQuestion tool to ask me one yes/no question. Do not run any command and do not use any other tool.'

wait_for 90 "the interactive question" pane_shows_question
wait_for 15 "the armed pending record" test -f "$MARKER"
marker_status_is pending || marker_status_is sent || fail "pending record has an unexpected status"
wait_for $((DELAY + 20)) "the nudge send" test -s "$SENT"
[ "$(cat "$SENT")" = "Captain, something's awaiting your attention." ] \
  || fail "expected exactly the content-free nudge, got: $(cat "$SENT")"
marker_status_is sent || fail "nudge sent but the record did not flip to sent"

# Answer the still-open question so the turn completes.
tmux send-keys -t "$TMUX_SESSION" Enter
wait_for 60 "disarm after the late answer" bash -c "[ ! -e '$MARKER' ]"
[ "$(grep -c Captain "$SENT")" = 1 ] || fail "more than one nudge for a single question"

# --- scenario 2: a prompt answered inside the delay never nudges -------------

: > "$SENT"
send_prompt 'Use the AskUserQuestion tool to ask me one more yes/no question. Do not run any command and do not use any other tool.'
wait_for 90 "the second interactive question" pane_shows_question
tmux send-keys -t "$TMUX_SESSION" Enter
wait_for 60 "disarm after the prompt answer" bash -c "[ ! -e '$MARKER' ]"
sleep $((DELAY + 4))
[ ! -s "$SENT" ] || fail "a promptly answered question still nudged: $(cat "$SENT")"

tmux send-keys -t "$TMUX_SESSION" -l '/exit'
tmux send-keys -t "$TMUX_SESSION" Enter

printf 'ok - Claude %s live E2E armed on a waiting question, nudged once content-free after %ss, and stayed silent for a promptly answered question\n' "$CLAUDE_VERSION" "$DELAY"
