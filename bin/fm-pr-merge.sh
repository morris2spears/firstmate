#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
#
# GitHub only auto-closes a linked issue when the PR body carries a real
# closing keyword ("Closes #N"); a bare "issue #N" mention is not enough and
# is easy for a crewmate to write by accident (seen live on iinvy #133/PR #134).
# Trusting every future PR body to phrase this correctly is not durable, so
# after a successful merge this script independently closes any GitHub issue
# this task's own backlog line already links, regardless of PR body wording.
# The backlog line - not the PR body - is the authority for "which issue this
# task addresses" because firstmate itself records that link at dispatch time.
# This step is best-effort and idempotent: a missing/manual-backend backlog,
# an unparseable line, or an already-closed issue are all silently skipped,
# and it never fails the merge itself.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_cipher_head_override() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --match-head-commit|--match-head-commit=*)
        echo "error: Cipher-gated merges bind the inspected PR head automatically" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

CIPHER_HEAD=
if fm_cipher_repo_gated "$PR_OWNER/$PR_REPO"; then
  reject_cipher_head_override "$@" || exit 1
  "$SCRIPT_DIR/fm-cipher-hook.sh" pr-ready "$ID" "$URL" || {
    echo "error: this Cipher-gated PR is not currently checks-green or its Cipher event is held" >&2
    exit 1
  }
  CIPHER_HEAD=$("$SCRIPT_DIR/fm-cipher-hook.sh" verify-merge \
    "$ID" "$URL" "${FM_CIPHER_MERGE_REQUEST_ID:-}") || {
      echo "error: this Cipher-gated merge remains held for Cipher's exact-head production inspection" >&2
      exit 1
    }
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi
if [ -n "$CIPHER_HEAD" ]; then
  merge_args+=(--match-head-commit "$CIPHER_HEAD")
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

close_linked_issues() {
  local backlog="$DATA/backlog.md" line issue_numbers n state
  [ -f "$backlog" ] || return 0
  line=$(grep -F "] $ID -" "$backlog" | head -n1) || return 0
  [ -n "$line" ] || return 0
  issue_numbers=$(printf '%s\n' "$line" \
    | grep -oE "github\.com/$PR_OWNER/$PR_REPO/issues/[0-9]+" \
    | grep -oE '[0-9]+$' | sort -u) || true
  [ -n "$issue_numbers" ] || return 0
  for n in $issue_numbers; do
    state=$(gh-axi issue view "$n" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null | grep -E '^ *state: ' | head -n1) || continue
    case "$state" in
      *open*) ;;
      *) continue ;;
    esac
    gh-axi issue close "$n" --repo "$PR_OWNER/$PR_REPO" --reason completed \
      --comment "Fixed by #$PR_NUMBER ($URL), merged." 2>&1 || true
  done
}
close_linked_issues
