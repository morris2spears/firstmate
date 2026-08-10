# Captain-attention nudge - Claude Code hook verification

Active empirical evidence for the hook contract `bin/fm-decision-nudge.sh` and the tracked `.claude/settings.json` registration rely on.
Re-verify against a newer Claude Code before trusting a behavior change in these events.

- Date: 2026-08-10
- Claude Code: 2.1.226
- macOS: 14.3 (Darwin 23.3.0, host mirage)
- Method: disposable interactive Claude Code session in a detached tmux session, project-scoped logging hooks appending every raw stdin payload to a file, driven with `tmux send-keys` and read with `tmux capture-pane`.

## Event contract (all observed live)

A waiting AskUserQuestion fires, in order:

```
{"event":"UserPromptSubmit"}
{"event":"PreToolUse","tool":"AskUserQuestion"}
{"event":"Notification","type":"permission_prompt","message":"Claude needs your permission"}
```

The raw Notification payload (identifiers abbreviated):

```
{"session_id":"2b32cd78-...","transcript_path":"...","cwd":"...","prompt_id":"02a98ad7-...",
 "hook_event_name":"Notification","message":"Claude needs your permission",
 "notification_type":"permission_prompt"}
```

A waiting permission dialog (Bash `mkdir` outside the workspace under `--permission-mode default`) fires the identical `Notification` event with `notification_type=permission_prompt`.

Resolution events:

- Answering the question fires `PostToolUse` with `tool_name=AskUserQuestion`.
- Approving a permission dialog runs the tool and fires `PostToolUse` for that tool.
- A normal turn end fires `Stop`.
- Any typed captain message fires `UserPromptSubmit` before the model runs.

Negative findings that shaped the design:

- The `Notification` event fired exactly once per waiting prompt; 75 unanswered seconds produced no repeat and no additional notification type.
- Declining a permission dialog with "No" fired no event at all (no `PermissionDenied`, no `Stop`), so a decline followed by 30 idle seconds still sends the one nudge; the next captain message clears the record.
  This is the documented residual in the script header.
- The `Notification` payload names no tool, and every tool call in one assistant block shares a `prompt_id`, so no field correlates a `PostToolUse` back to the waiting prompt. The disarm is therefore matcher `.*` and uncorrelated: a sibling tool finishing while the dialog still waits drops that turn's nudge. Narrowing it would be a worse trade, because `PostToolUse` for an approved tool fires only when that tool finishes - a correlated disarm would page the captain on every approved command that outlives the delay. A missed page in the parallel case (where he is at the keyboard, having just seen the dialog) is the cheaper side. This is the second documented residual in the script header.
- `permission_mode` in the payload was `bypassPermissions` during the AskUserQuestion capture, so the question prompt notifies regardless of permission mode.

## Verification procedure

1. `bash tests/fm-decision-nudge.test.sh` - the fast behavior suite drives arm, one-nudge delivery, dedup, disarm, opt-in gating, primary-scope gating, notification-type filtering, stale-timer safety, and the settings registration, using payloads byte-shaped from the captures above and a capture stub for the Telegram client.
2. `FM_CLAUDE_LIVE_E2E=1 bash tests/fm-decision-nudge-live-e2e.test.sh` - the opt-in credentialed regression clones the repo with its tracked hooks, drives a real interactive Claude Code session to a waiting AskUserQuestion in tmux, and proves the unanswered path nudges exactly once content-free while the promptly answered path stays silent.

Run 2 recorded on 2026-08-10 against Claude Code 2.1.226:

```
ok - Claude 2.1.226 (Claude Code) live E2E armed on a waiting question, nudged once content-free after 8s, and stayed silent for a promptly answered question
```
