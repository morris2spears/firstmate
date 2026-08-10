#!/usr/bin/env bash
# Captain-attention nudge for firstmate PRIMARY sessions (Claude Code and Pi).
#
# When the primary session waits on a direct captain decision - Claude Code's
# AskUserQuestion tool or a permission dialog, or a settled Pi turn that ends
# by asking the captain something - and he has not answered within
# FM_DECISION_NUDGE_DELAY_SECS (default 30), send him ONE deliberately
# content-free Telegram message through the phone-inbox tg client. The nudge
# never describes the question; if he asks what it is from his phone, the
# existing Telegram-mode flow (fmtg-respond) answers normally.
#
# Hook wiring (.claude/settings.json, this repo only - never the captain's
# global settings). Event payloads below were captured live from Claude Code
# 2.1.226 (docs/verification/decision-nudge.md):
#   Notification matcher permission_prompt  -> --claude-pending   (arm)
#     Fires once when AskUserQuestion is waiting AND when a permission dialog
#     is waiting; both carry notification_type=permission_prompt. It does not
#     repeat while the same prompt stays unanswered.
#   PostToolUse matcher .*                  -> --claude-resolved  (disarm)
#     The question was answered or the permitted tool ran to completion.
#     Deliberately uncorrelated: the Notification payload names no tool and
#     parallel calls in one block share prompt_id, so any completed tool
#     disarms. See "Known residuals" on why this stays the coarse rule.
#   UserPromptSubmit                        -> --claude-resolved  (disarm)
#     The captain typed something, so he is present.
#   Stop                                    -> --claude-resolved  (disarm)
#     The turn ended, so nothing is blocking.
#   (internal) --wait <nonce>               -> detached 30s timer
#
# Pi wiring (.pi/extensions/fm-primary-decision-nudge.ts):
#   agent_settled      -> --pi-arm <assistant entry id> (arm after heuristic)
#   input              -> --pi-resolved (disarm on genuine captain presence)
#   before_agent_start -> --pi-resolved (disarm before any next run)
#   session_shutdown   -> --pi-resolved (disarm when this session leaves)
# The Pi extension passes only the assistant entry id, never the question text.
#
# Known Claude residuals (both verified live, both accepted):
#   1. Declining a permission dialog with "No" aborts the turn without firing
#      any hook event, so a decline followed by 30 idle seconds still sends
#      the one nudge. The session genuinely is idle awaiting the captain's
#      next instruction at that point, and his next message clears the
#      record, so this stays a harmless near-miss rather than a repeat pager.
#   2. The disarm is uncorrelated, so a sibling tool finishing while the
#      dialog still waits (parallel tool block, background or subagent
#      completion) drops that turn's nudge. This is a missed page, not a
#      spurious one, and narrowing it is a worse trade: PostToolUse for an
#      approved tool only fires when that tool FINISHES, so a correlated
#      disarm would page the captain every time he approves a command that
#      runs longer than the delay - a frequent false positive traded for a
#      rare false negative. The captain is at the keyboard in the parallel
#      case (he just saw the dialog), so the coarse rule stays.
#
# Scope and consent:
#   - fm_primary_scope_matches gates arming, so crewmate/scout task worktrees
#     of this repo (linked worktrees, no secondmate marker) never nudge.
#   - Telegram mode's opt-in flag (config/telegram-mode, fmtg_enabled) gates
#     every send: without the captain's standing opt-in this script arms
#     nothing and sends nothing, matching the away-mode escalation precedent
#     in bin/fm-supervise-daemon.sh.
#   - The message text travels to the tg client on stdin only, and this
#     script never reads or prints any credential.
#
# Pending-marker protocol (state/.decision-nudge-pending):
#   prompt_id=<claude prompt id>|pi:<Pi assistant entry id>
#                                  identifies the harness wait
#   nonce=<pid.epoch.random>       binds the marker to its own timer
#   status=pending|sent            sent suppresses re-arming for the same turn
# The marker is private volatile state; disarm simply removes it. One nudge
# per prompt_id: a second permission_prompt notification in the same turn
# (e.g. decline, then a different tool prompts) keeps the original timer.
#
# The arm hook must never delay the interactive prompt: it validates, writes
# the marker, double-fork-detaches the timer, and exits immediately.
#
# Environment overrides (tests): FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE,
# FM_CONFIG_OVERRIDE, FM_DECISION_NUDGE_DELAY_SECS, FMTG_TG_BIN.
#
# Other harnesses: this covers Claude Code and Pi/pi-signed primaries. The
# remaining primary harnesses are a known follow-up. See docs/configuration.md
# "Captain-attention nudge".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MARKER="$STATE/.decision-nudge-pending"
DELAY=${FM_DECISION_NUDGE_DELAY_SECS:-30}
case "$DELAY" in ''|*[!0-9]*|0) DELAY=30 ;; esac

MODE="${1:-}"

# Both resolve modes are on the hot path of every tool call and turn end, so
# they exit before any sourcing, JSON parsing, or scope work; the common
# no-marker case costs one stat.
# The --claude-resolved drain is not optional: PostToolUse payloads embed
# tool_response, which routinely exceeds the pipe buffer, and exiting with the
# pipe unread would EPIPE the harness mid-write. --pi-resolved is spawned by
# the Pi extension with stdio ignored, so it has no payload to drain.
if [ "$MODE" = --claude-resolved ] || [ "$MODE" = --pi-resolved ]; then
  [ "$MODE" = --claude-resolved ] && { cat >/dev/null 2>&1 || true; }
  [ -e "$MARKER" ] || exit 0
  rm -f "$MARKER" 2>/dev/null || true
  exit 0
fi

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

marker_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

case "$MODE" in
  --claude-pending|--pi-arm)
    if [ "$MODE" = --claude-pending ]; then
      # Reading stdin first keeps the hook pipe drained even on an early exit.
      PAYLOAD=$(cat 2>/dev/null || true)
      [ -n "$PAYLOAD" ] || exit 0
      # jq is the repo's established JSON dependency; without it degrade to a
      # silent no-op exactly like the turn-end guard.
      command -v jq >/dev/null 2>&1 || exit 0
      NTYPE=$(printf '%s' "$PAYLOAD" | jq -r '.notification_type // ""' 2>/dev/null) || exit 0
      [ "$NTYPE" = permission_prompt ] || exit 0
      PROMPT_ID=$(printf '%s' "$PAYLOAD" | jq -r '.prompt_id // .session_id // "unknown"' 2>/dev/null) || exit 0
    else
      # The Pi extension already applied the captain-facing-ask heuristic; all
      # that arrives here is the assistant entry id it settled on.
      ENTRY_ID=${2:-}
      [ -n "$ENTRY_ID" ] || exit 0
      case "$ENTRY_ID" in *$'\n'*|*$'\r'*) exit 0 ;; esac
      PROMPT_ID="pi:$ENTRY_ID"
    fi
    fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
    # No standing Telegram opt-in means the whole feature stays inert.
    fmtg_enabled "$FM_HOME" || exit 0
    if [ -f "$MARKER" ] && [ "$(marker_field "$MARKER" prompt_id)" = "$PROMPT_ID" ]; then
      # Same user turn: either the timer is already running or the one nudge
      # for this turn was already sent. Never arm a second timer.
      exit 0
    fi
    NONCE="$$.$(date +%s).$RANDOM"
    TMP="$MARKER.tmp.$$"
    {
      printf 'prompt_id=%s\n' "$PROMPT_ID"
      printf 'nonce=%s\n' "$NONCE"
      printf 'status=pending\n'
    } > "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 0; }
    mv -f "$TMP" "$MARKER" 2>/dev/null || { rm -f "$TMP"; exit 0; }
    # Double-fork detach: the subshell exits at once, the timer reparents to
    # init with every fd off the hook pipe, and the interactive prompt renders
    # without waiting on anything.
    ( nohup "$SELF" --wait "$NONCE" </dev/null >/dev/null 2>&1 & )
    exit 0
    ;;
  --wait)
    NONCE="${2:-}"
    [ -n "$NONCE" ] || exit 0
    sleep "$DELAY"
    [ -f "$MARKER" ] || exit 0
    [ "$(marker_field "$MARKER" status)" = pending ] || exit 0
    [ "$(marker_field "$MARKER" nonce)" = "$NONCE" ] || exit 0
    PROMPT_ID=$(marker_field "$MARKER" prompt_id)
    # Claim before sending so a racing disarm or duplicate timer can never
    # produce two nudges: exactly one mv wins.
    CLAIM="$MARKER.claim.$$"
    mv -f "$MARKER" "$CLAIM" 2>/dev/null || exit 0
    if [ "$(marker_field "$CLAIM" nonce)" != "$NONCE" ]; then
      mv -f "$CLAIM" "$MARKER" 2>/dev/null || true
      exit 0
    fi
    if ! fmtg_enabled "$FM_HOME" || ! fmtg_client_runnable; then
      rm -f "$CLAIM"
      exit 0
    fi
    printf '%s\n' "Captain, something's awaiting your attention." | fmtg_send_stdin >/dev/null 2>&1 || {
      rm -f "$CLAIM"
      exit 0
    }
    # Leave a sent record for this prompt_id so a late duplicate notification
    # in the same turn cannot re-arm; the next disarm event removes it.
    {
      printf 'prompt_id=%s\n' "$PROMPT_ID"
      printf 'nonce=%s\n' "$NONCE"
      printf 'status=sent\n'
    } > "$CLAIM" 2>/dev/null || true
    mv -f "$CLAIM" "$MARKER" 2>/dev/null || rm -f "$CLAIM"
    exit 0
    ;;
  *)
    echo "usage: $(basename "$0") --claude-pending | --claude-resolved | --pi-arm <entry-id> | --pi-resolved | --wait <nonce>" >&2
    exit 2
    ;;
esac
