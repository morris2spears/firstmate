# Carbon peer relay

The carbon peer relay lets a captain-facing Claude Code orchestrator session on `carbon` send a request to the live primary Firstmate on `mirage` and receive the answer in the same originating tmux pane.
It follows the existing external-channel shape: a durable pending record, an authenticated watcher check, an ids-only `check:` notification, a situation-specific response skill, and a reply that resolves the record only after confirmed delivery.

## Activation

The relay is inert until the primary Firstmate home contains the regular, non-symlink flag file `config/peer-relay-carbon`.
The flag contains no credential.
SSH account access and the existing fleet keys are the trust boundary, so this channel has the same captain authority as direct input in the primary session.

After creating the flag, run the normal locked session-start bootstrap path.
Bootstrap writes `state/peer-relay-watch.check.sh`, binds its exact bytes with the generic custom-check trust record, and keeps the relay in the set of features that require one live supervision cycle even when no project work is under way.
Removing the flag and running locked session start removes those generated poll artifacts.

Install the tracked client script on carbon at `~/.local/bin/fm-peer-relay-tell.sh` and make it executable.
A carbon orchestrator can then relay one line with:

```sh
~/.local/bin/fm-peer-relay-tell.sh "the captain's request"
```

It can relay multiline input without placing it in process arguments with:

```sh
printf '%s' "the captain's request" | ~/.local/bin/fm-peer-relay-tell.sh --stdin
```

The default client SSH target is `mirage`.
The default remote command is `FM_HOME=$HOME/kun-agent-workspace $HOME/kun-agent-workspace/bin/fm-peer-relay-receive.sh`.
The script's `--help` output owns the environment overrides for installations that use different aliases or paths.

## Request envelope and durable record

The carbon client requires `TMUX_PANE`, verifies that exact pane still exists, and captures its tmux pane id, stable window id, session name, short hostname, and current epoch before opening SSH.
It sends this versioned stdin envelope, followed by the raw message after the blank line:

```text
fm-peer-relay-v1
origin_host=carbon
pane_id=%42
session_name=work
window_id=@7
client_epoch=1785600000

<raw captain message>
```

The receiver accepts only an explicit absolute `FM_HOME`, an enabled home, an SSH invocation, the `carbon` origin, structurally valid tmux identities, and a message from 1 through 65536 bytes.
It atomically publishes a private mode-`0700` request directory under `state/peer-relay/requests/<request-id>/`.
The directory contains mode-`0600` `meta`, `message`, and `status` files with the request id, raw message, origin, exact reply pane identity, client and receive timestamps, and current delivery state.

The receiver then makes the authenticated poll due on the next ordinary watcher tick.
`bin/fm-peer-relay-poll.sh` emits only ids, as `peer-relay-request <id> [<id>...]`, or the ids-free diagnostic below, and the watcher writes that output through the existing durable `check:` wake queue path before notifying Firstmate.
Neither the request body nor the reply appears in watcher output, a wake payload, or an artifact filename.
An ids-only offer marker suppresses duplicates and re-offers an unanswered pending request after `FMPEER_REOFFER_SECS`, whose default is 1800 seconds.
If an offer marker is not a valid private artifact, or an offer cannot be recorded, the poll never emits around it silently: it surfaces one deduplicated `peer-relay-error <message>` line instead, so a stranded request is visible rather than stuck in pending forever.
That wake routes to the `fmpeer-respond` skill, which clears the blocker and answers the stranded pending requests, exactly as `tg-mode-error` routes to `fmtg-respond`.

## Retention

The poll prunes each request record that reached a terminal delivery state, `resolved` or `delivery-uncertain`, once its status is older than `FMPEER_RETENTION_SECS`, whose default is 604800 seconds.
Pruning removes the whole record, including the stored request and reply text, and orphaned offer markers go with it.
A pending request is never pruned: only the captain's own reply moves a record out of pending.

## Acting and replying

The `fmpeer-respond` skill owns request handling.
It inspects each pending id, treats the message exactly like direct captain input, acts through the normal Firstmate lifecycle, and composes a concise captain-facing answer.
This relay does not inherit Telegram or X mode's reduced authority because the request arrived through the captain's trusted peer SSH path.

The skill sends the answer with `bin/fm-peer-relay-reply.sh`.
That helper records the reply and `sending` state before network I/O, then invokes `~/.local/bin/fm-peer-relay-tell.sh`, expanded by the remote login shell, over `ssh carbon` with the recorded pane id and reply body on stdin.
The carbon helper verifies the exact pane id, runs one literal `tmux send-keys -l` for the text, and runs a separate `tmux send-keys ... Enter` to submit it.
A confirmed SSH success changes the durable state to `resolved`.
Any nonzero delivery changes it to `delivery-uncertain`, because the text or Enter may already have arrived, and a blind retry is forbidden.

## Current scope

This pass supports the concrete `carbon` peer only.
The record and envelope keep origin identity separate from tmux identity so another trusted peer can be added later without changing the request lifecycle, but there is intentionally no multi-peer registry or pairing-token layer.
The client currently targets tmux panes, not window names, because the captain may reshuffle carbon's window layout at any time.
