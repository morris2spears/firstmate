---
name: cipher-hook
description: >-
  Agent-only playbook for a genuine needs-decision transition, an iinvy checks-green transition, or an authenticated cipher-comment or cipher-retry check notification.
  It owns the Cipher authority split, durable GitHub answer fetch, iinvy merge hold, held-delivery retry outcomes, and local receive command that avoids primary-pane ambiguity.
user-invocable: false
metadata:
  internal: true
---

# Cipher hook

Load this after current-state reconciliation proves a genuine `needs-decision`, when a checks-green pull request belongs to `morris2spears/iinvy` or `morris2spears/iinvy-storefront`, or on a `cipher-comment` or `cipher-retry` check notification.
The local setup and wire schema are owned by [`docs/configuration.md`](../../../docs/configuration.md#cipherhermes-bridge), while the command contracts are owned by the headers of [`bin/fm-cipher-hook.sh`](../../../bin/fm-cipher-hook.sh) and [`bin/fm-cipher-receive.sh`](../../../bin/fm-cipher-receive.sh).

## Genuine needs-decision

Reconcile the worker with `bin/fm-crew-state.sh <id>` before treating an old status event as current.
Read the open decision key from the durable keyed-decision fold rather than copying the worker's summary into a command.
Run `bin/fm-cipher-hook.sh needs-decision <id> <decision-key>`.
Exit 0 means Cipher accepted the stable logical event, so leave the worker parked and do not answer its finding.
Exit 3 means this home has no enabled decision route, so continue through the existing `ask-user-authority` procedure.
Any other nonzero result means delivery is durably held, so surface the one concrete configuration or gateway blocker and do not answer the finding.

Cipher may select only a routine, reversible option inside the accepted GitHub issue contract.
Cipher must instead escalate to Morris for an unsafe or uncertain recommendation, contract expansion, destructive or irreversible action, security or credential change, production-data migration, or spending.
The implementation worker never answers its own finding.

## Durable GitHub answer

An authenticated `cipher-comment decision-comment ...` notification points to the exact GitHub comment Cipher wrote before asking Firstmate to continue.
Fetch that exact comment with `gh-axi`, verify that it names the open decision and records the recommendation, selected option, reasoning, and reversal path, then load `ask-user-authority` as defense in depth before sending the worker the normal exact gate response.
If the comment escalates to Morris or does not contain a safe complete selection, keep the worker parked.
Never use gateway response prose as the decision ledger because GitHub is authoritative.

## Iinvy checks-green boundary

`bin/fm-pr-check.sh` emits the exact-head event automatically after it records a checks-green iinvy PR.
A missing or disabled route, timeout, unavailable gateway, invalid acknowledgement, or delivery failure keeps the merge held.
Do not invoke the ordinary merge command for either gated repository, even after event delivery succeeds.
Cipher alone invokes `bin/fm-cipher-hook.sh merge <id> <PR-url> <request-id>` after its narrow production-outage inspection, and that command still enters the guarded merge helper with an exact-head condition.
Cipher's inspection is limited to cross-repository provider and consumer contracts, migration or deployment order, runtime install/import/restart behavior, and production-realistic health or smoke gates.
It does not repeat code review, style review, architecture review, or no-mistakes review.
The post-merge deployment and health verification plus durable-link Discord receipt are Cipher-side acceptance owned by the configuration reference, not a Firstmate notification step.

An authenticated `cipher-comment pr-blocker ...` notification points to Cipher's exact production-outage evidence on the owning GitHub issue or PR.
Fetch that comment with `gh-axi`, relay the outcome in captain-facing language when needed, and return the evidence to the task's own worker through the existing fix path.
Do not merge until the blocker is resolved, checks are green again, and a new exact-head event is emitted.

## Automatic retry of held deliveries

A delivery held for a transient gateway failure (unavailable, timeout, transient HTTP) is retried automatically by live monitoring on its slow check cadence, with the same recorded body and request ID, so gateway recovery needs no manual record edits or re-triggering.
A `cipher-retry` check notification reports only the outcomes: `delivered <request-id> <event> <task-id>` means the previously held event has now reached Cipher, so resume the normal post-delivery behavior for that event and update the captain if the outage was previously reported.
`superseded <request-id> (<why>)` means the held event became obsolete before delivery - the decision was answered through the existing authority, the PR head advanced so a fresh exact-head event owns the transition, or the task's records are gone - and it will never be delivered; no action is needed beyond noting it.
A held pull-request event whose checks are simply not green at the moment is not superseded, because checks can regress and come back green on the same head under the same request identity; it keeps retrying until delivery or until the task's records are gone.
A hold for a configuration-class failure (missing or invalid route configuration, bad secret, non-transient HTTP rejection, invalid acknowledgement) is deliberately never auto-retried: surface the concrete blocker, and after the captain repairs it re-run the original trigger command, which adopts the recorded request and retries the exact same event.

## Pane-independent return path

Hermes calls `bin/fm-cipher-receive.sh` with the task, acknowledged request, and exact GitHub comment URL after it writes a decision or blocker.
That command validates the event binding and appends one durable notification directly to the owning Firstmate home's queue.
It never scans or writes terminal panes, so a self-repo ship worker cannot masquerade as another primary and the exactly-one-primary safety check remains intact for transports that actually address a primary pane.
Handle its notification through the ordinary wake-drain and supervision continuation, preserving X, Telegram, and away-mode behavior.
