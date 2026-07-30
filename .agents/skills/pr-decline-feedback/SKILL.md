---
name: pr-decline-feedback
description: >-
  Agent-only playbook for a pull request the captain declined by closing it without merging after leaving a comment on it.
  Use on a "check:" wake whose poll result is "declined <number> <comment-id>", before relaying that comment.
  Owns the read of the comment, the authority boundary that makes the relay autonomous, the handoff back to the task's own worker, and the case where the worker is already gone.
user-invocable: false
metadata:
  internal: true
---

# Declined pull request

## What the wake means

`check: <path>/<id>.check.sh: declined <number> <comment-id>` means the task's pull request is closed, was never merged, and carries a comment written by the account this home is authenticated to the forge as.
That is the captain declining the work and saying what to change.
It is not GitHub's formal "request changes" review, and the poll does not look for one: the captain's habit is a plain comment followed by a close.

The wake fires once per distinct captain comment.
The poll is stateless and reports the same newest comment on every cycle; `state/<id>.pr-decline-seen` is what turns those repeats into one relay.
Never hand-edit or delete that record to force a re-relay - resend the instruction with `bin/fm-send.sh` instead.

A second wake for the same task means the captain said something *new*.
Read it and relay it on top of the work already under way rather than restarting the task.

## Authority

Relaying this comment to the task's worker and restarting its delivery path is autonomous.
It needs no captain approval and no `yolo` posture, because the captain already gave the instruction: the comment plus the close *is* the decision.
Do not escalate "should I act on this?" back to him.

This changes nothing else about approval authority.
In particular it is not an ask-user finding and does not touch `ask-user-authority`, which still owns every decision the worker's own pipeline discovers mid-run.
If the pipeline later hits a genuine ask-user finding while acting on this feedback, that escalates exactly as it always did.
The stronger boundaries hold unchanged: a merge still needs the configured merge authority, and destructive, irreversible, or security-sensitive choices still need the captain.

Two things in the comment are *not* autonomous.
If it asks for work outside the original request and accepted task criteria, or for something destructive, irreversible, or security-sensitive, relay only the in-scope part and escalate the rest with the captain's own words as the evidence.

## Procedure

1. Read the comment. The task id is the check file's stem, and `pr=` in `state/<id>.meta` is the pull request. Fetch the body with `gh-axi` (or `gh pr view <url> --json comments`) and match `<comment-id>`. The poll deliberately carries no prose, so this read is where you learn what he wants.
2. Sanity-check the author before acting. The poll already matched the authenticated account, but a comment that is plainly a bot summary, a CI report, or the crew's own pipeline note is not an instruction: report it to the captain as a question instead of relaying it.
3. Reconcile the worker with `bin/fm-crew-state.sh <id>`. A ship task that reported `done` usually still has its worker and its branch.
4. Steer the live worker with one short `bin/fm-send.sh` line: the pull request was declined and closed, what he asked to change, and that it must go back through the task's selected delivery path to a new pull request. Put a long comment in a file and send the path.
5. If the worker is gone, load `stuck-crewmate-recovery` first and reconcile the recorded worktree; never tear down the branch to start over.
6. Update the backlog item: the work is back under way, not done.
7. Tell the captain in one line that his feedback is with the worker. Do not re-ask what he already said.

## Boundaries

Do not merge, reopen, or close anything on the forge in response to this wake.
Do not tear the task down: a decline is not terminal, the poll stays armed, and it still retires normally on the merge that follows the revisions.
Detection is GitHub-only, so a GitLab merge request never produces this wake; `bin/fm-pr-poll.sh` owns that limit and the exact signal shape, and `bin/fm-pr-lib.sh` owns the delivery record.
