---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain decisions.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Durable unresolved-decision lifecycle

This skill is the single policy owner for unresolved captain decisions discovered by an investigation or visual review.

## Policy

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured captain-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
The agent performs the semantic inventory because scripts must not infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative Captain's Call item until the captain's exact answer or disposition evidence is durably recorded through one of two explicit paths.
When the answer commissions dependent work, create that work in the same backlog, block it by the hold, and use `bin/fm-decision-hold.sh resolve` to route the answer by clearing those dependency edges before closing the hold.
When the decision was implemented already, superseded, declined, or answered without commissioning new work, use the same owner's `terminal` command with the matching explicit disposition and exact evidence file; this path neither requires nor creates a downstream task.
Never use a terminal disposition to infer an answer, hide an unresolved or deferred choice, or bypass separately authorized implementation work.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. After the captain decides, choose the routed or terminal path from the policy above without inventing work.
7. For routed implementation, record dependent work with normal tasks-axi commands, block it by the hold identity, put the captain's exact durable decision in a file, and use the script's `resolve` command with every routed task.
8. For an already terminal outcome, put the exact decision or disposition evidence in a file and use the script's `terminal` command with its explicit disposition.
9. Confirm Bearings no longer shows the closed hold, genuine unresolved decisions remain visible, and any separately queued or routed work retains its structured backlog state.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
