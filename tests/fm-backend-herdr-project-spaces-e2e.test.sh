#!/usr/bin/env bash
# tests/fm-backend-herdr-project-spaces-e2e.test.sh - mandatory ISOLATED
# end-to-end real-herdr test for the per-project shared-workspace layout
# (docs/herdr-backend.md "Project workspaces"). Drives the REAL bin/fm-spawn.sh
# and bin/fm-teardown.sh, because the properties under test - config-mode
# routing, adopt-or-create under the session lock, the herdr_project_space=1
# teardown routing, and captain-tab survival - only exist at that level.
#
# Mirrors tests/fm-backend-herdr-workspace-per-home-e2e.test.sh's
# isolated-session convention: a private throwaway HERDR_SESSION (never the
# captain's default), a scratch FM_HOME, and scratch local-only projects.
# Cleanup uses ONLY herdr_safe_stop_and_delete (tests/herdr-test-safety.sh).
#
# Covers, per the task brief:
#   - two tasks for ONE project sharing one project-named workspace
#   - a task for a DIFFERENT project landing in a different workspace
#   - an unrelated (captain) tab surviving each task's teardown, including the
#     last task's, with the shared workspace itself surviving
#   - a tampered adoption binding falling back loudly to the flat layout,
#     leaving the captain's own workspace untouched
#   - the flat default (flag absent) unchanged in the same session
#   - a --secondmate spawn keeping its per-home placement even in project mode
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-proj-e2e.XXXXXX")
SESSION="fm-lab-herdr-proj-$$"
export HERDR_SESSION="$SESSION"
WORKTREES=()
cleanup_all() {
  local wt
  for wt in ${WORKTREES[0]:+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$wt" >/dev/null 2>&1
  done
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" \
  "$HOME_DIR/data/pj1" "$HOME_DIR/data/pj2" "$HOME_DIR/data/pj3" "$HOME_DIR/data/pj4" "$HOME_DIR/data/pj5"
for id in pj1 pj2 pj3 pj4 pj5; do
  printf 'trivial e2e crewmate brief: nothing to do.\n' > "$HOME_DIR/data/$id/brief.md"
done
printf 'project\n' > "$HOME_DIR/config/herdr-presentation-spaces"

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME/state" "$SM_HOME/data" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf 'pje2esm\n' > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

PROJ1="$TMP_ROOT/alpha-app"; make_scratch_project "$PROJ1"
PROJ2="$TMP_ROOT/beta-app"; make_scratch_project "$PROJ2"

spawn_task() {  # <id> <project> [extra spawn args...] -> stdout/err files under TMP_ROOT
  local id=$1 proj=$2
  shift 2
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo crew-$id-ok'" --backend herdr "$@" \
    >"$TMP_ROOT/$id.out" 2>"$TMP_ROOT/$id.err"
}

meta_field() {  # <id> <key>
  grep "^$2=" "$HOME_DIR/state/$1.meta" | cut -d= -f2-
}

record_worktree() {  # <id>
  local wt
  wt=$(meta_field "$1" worktree)
  [ -n "$wt" ] && WORKTREES+=("$wt")
}

workspace_of_pane() {  # <pane>
  herdr pane get "$1" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.workspace_id // empty'
}

workspace_label() {  # <workspace-id>
  herdr workspace list --session "$SESSION" 2>&1 \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .label'
}

# --- 1. two tasks for ONE project share one project-named workspace ----------

spawn_task pj1 "$PROJ1" || fail "spawn pj1 failed"$'\n'"$(cat "$TMP_ROOT/pj1.out" "$TMP_ROOT/pj1.err")"
record_worktree pj1
PJ1_PANE=$(meta_field pj1 herdr_pane_id)
[ "$(meta_field pj1 herdr_project_space)" = 1 ] || fail "pj1 meta missing herdr_project_space=1"
PJ1_WS=$(workspace_of_pane "$PJ1_PANE")
[ -n "$PJ1_WS" ] || fail "could not read pj1's workspace"
PJ1_LABEL=$(workspace_label "$PJ1_WS")
case "$PJ1_LABEL" in
  "alpha-app · p:"??????????????????????) : ;;
  *) fail "project workspace label should be 'alpha-app · p:<22-char-token>', got '$PJ1_LABEL'" ;;
esac
pass "real herdr E2E: the first task creates the 'alpha-app · p:<token>' project workspace"

JOURNAL=$(bash -c '. "$0/bin/backends/herdr.sh"
  p=$(fm_backend_herdr_project_identity "$2") || exit 1
  fm_backend_herdr_project_journal_path "$1" "$p"' "$ROOT" "$HOME_DIR/state" "$PROJ1")
[ -f "$JOURNAL" ] || fail "no project journal at $JOURNAL"
assert_contains_local "$(cat "$JOURNAL")" "version=2" "the project journal should be a bound version 2"
assert_contains_local "$(cat "$JOURNAL")" "workspace_id=$PJ1_WS" "the journal should bind pj1's exact workspace"

spawn_task pj2 "$PROJ1" || fail "spawn pj2 failed"$'\n'"$(cat "$TMP_ROOT/pj2.out" "$TMP_ROOT/pj2.err")"
record_worktree pj2
PJ2_PANE=$(meta_field pj2 herdr_pane_id)
PJ2_WS=$(workspace_of_pane "$PJ2_PANE")
[ "$PJ2_WS" = "$PJ1_WS" ] || fail "a second task for the same project must ADOPT the same workspace ($PJ1_WS), got '$PJ2_WS'"
[ "$PJ2_PANE" != "$PJ1_PANE" ] || fail "the two tasks must have distinct panes"
pass "real herdr E2E: a second task for the same project adopts the same project workspace"

# The seeded default tab must have been pruned: only the two task tabs remain.
TAB_LABELS=$(herdr tab list --workspace "$PJ1_WS" --session "$SESSION" 2>&1 | jq -r '.result.tabs[].label' | LC_ALL=C sort | tr '\n' ' ')
[ "$TAB_LABELS" = "fm-pj1 fm-pj2 " ] || fail "the project workspace should hold exactly the two task tabs, got '$TAB_LABELS'"
pass "real herdr E2E: the created workspace's seeded default tab was pruned and only task tabs remain"

# --- 2. a task for a DIFFERENT project lands in a different workspace --------

spawn_task pj3 "$PROJ2" || fail "spawn pj3 failed"$'\n'"$(cat "$TMP_ROOT/pj3.out" "$TMP_ROOT/pj3.err")"
record_worktree pj3
PJ3_PANE=$(meta_field pj3 herdr_pane_id)
PJ3_WS=$(workspace_of_pane "$PJ3_PANE")
[ -n "$PJ3_WS" ] && [ "$PJ3_WS" != "$PJ1_WS" ] || fail "a different project must get a different workspace, got '$PJ3_WS'"
PJ3_LABEL=$(workspace_label "$PJ3_WS")
case "$PJ3_LABEL" in
  "beta-app · p:"*) : ;;
  *) fail "the second project's workspace should be labeled 'beta-app · p:<token>', got '$PJ3_LABEL'" ;;
esac
pass "real herdr E2E: a task for a different project lands in its own project workspace"

# --- 3. an unrelated captain tab survives task teardown ----------------------

DEV_TAB_OUT=$(herdr tab create --workspace "$PJ1_WS" --cwd "$PROJ1" --label devserver --no-focus --session "$SESSION" 2>&1) \
  || fail "could not create the captain's devserver tab"
DEV_TAB=$(printf '%s' "$DEV_TAB_OUT" | jq -r '.result.tab.tab_id // empty')
DEV_PANE=$(printf '%s' "$DEV_TAB_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$DEV_TAB" ] && [ -n "$DEV_PANE" ] || fail "no ids for the captain's devserver tab"
# The captain is watching the dev server, not a task tab: the focus-preserving
# close correctly refuses to close whatever tab is active, so put the lab's
# focus where a real captain's would be before tearing tasks down.
herdr tab focus "$DEV_TAB" --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not focus the captain's devserver tab"

teardown_task() {  # <id>
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-teardown.sh" "$1" >"$TMP_ROOT/$1.td.out" 2>&1
}

teardown_task pj1 || fail "teardown pj1 failed"$'\n'"$(cat "$TMP_ROOT/pj1.td.out")"
herdr pane get "$PJ1_PANE" --session "$SESSION" >/dev/null 2>&1 && fail "teardown did not close pj1's pane"
herdr pane get "$PJ2_PANE" --session "$SESSION" >/dev/null 2>&1 || fail "teardown pj1 must not close pj2's pane"
herdr pane get "$DEV_PANE" --session "$SESSION" >/dev/null 2>&1 || fail "teardown pj1 must not close the captain's devserver pane"
pass "real herdr E2E: tearing down one task closes only its own pane; the sibling task and the captain's tab survive"

teardown_task pj2 || fail "teardown pj2 failed"$'\n'"$(cat "$TMP_ROOT/pj2.td.out")"
herdr pane get "$PJ2_PANE" --session "$SESSION" >/dev/null 2>&1 && fail "teardown did not close pj2's pane"
herdr pane get "$DEV_PANE" --session "$SESSION" >/dev/null 2>&1 \
  || fail "tearing down the LAST task must not close the captain's devserver pane"
PJ1_WS_STILL=$(workspace_label "$PJ1_WS")
[ "$PJ1_WS_STILL" = "$PJ1_LABEL" ] || fail "the shared project workspace must survive while the captain's tab remains, got label '$PJ1_WS_STILL'"
pass "real herdr E2E: the last task's teardown leaves the captain's tab and the shared workspace alive"

# --- 4. a tampered binding falls back loudly to flat, touching nothing -------

CAPTAIN_WS_OUT=$(herdr workspace create --cwd "$TMP_ROOT" --label beta-app --no-focus --session "$SESSION" 2>&1) \
  || fail "could not create the captain's own beta-app workspace"
CAPTAIN_WS=$(printf '%s' "$CAPTAIN_WS_OUT" | jq -r '.result.workspace.workspace_id // empty')
CAPTAIN_SEED_PANE=$(printf '%s' "$CAPTAIN_WS_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$CAPTAIN_WS" ] && [ -n "$CAPTAIN_SEED_PANE" ] || fail "no ids for the captain's beta-app workspace"

JOURNAL2=$(bash -c '. "$0/bin/backends/herdr.sh"
  p=$(fm_backend_herdr_project_identity "$2") || exit 1
  fm_backend_herdr_project_journal_path "$1" "$p"' "$ROOT" "$HOME_DIR/state" "$PROJ2")
[ -f "$JOURNAL2" ] || fail "no journal for beta-app at $JOURNAL2"
sed -i.bak "s/^workspace_id=.*/workspace_id=$CAPTAIN_WS/" "$JOURNAL2" && rm -f "$JOURNAL2.bak"

spawn_task pj4 "$PROJ2" || fail "spawn pj4 failed"$'\n'"$(cat "$TMP_ROOT/pj4.out" "$TMP_ROOT/pj4.err")"
record_worktree pj4
assert_contains_local "$(cat "$TMP_ROOT/pj4.err")" "not provably firstmate's own container" \
  "the tampered binding should fall back with the provability warning"
PJ4_PANE=$(meta_field pj4 herdr_pane_id)
PJ4_WS=$(workspace_of_pane "$PJ4_PANE")
[ "$PJ4_WS" != "$CAPTAIN_WS" ] || fail "the spawn must NOT adopt the captain's own workspace"
[ "$(workspace_label "$PJ4_WS")" = "firstmate" ] || fail "the fallback should land in the flat 'firstmate' workspace, got '$(workspace_label "$PJ4_WS")'"
[ "$(meta_field pj4 herdr_project_space)" = "" ] || fail "a flat-fallback task must not record herdr_project_space"
herdr pane get "$CAPTAIN_SEED_PANE" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the captain's own workspace pane must be untouched by the fallback"
pass "real herdr E2E: a binding pointing at the captain's own workspace is refused loudly and falls back flat, touching nothing"

teardown_task pj4 || fail "teardown pj4 failed"$'\n'"$(cat "$TMP_ROOT/pj4.td.out")"

# --- 5. flat default (flag absent) unchanged in the same session -------------

rm -f "$HOME_DIR/config/herdr-presentation-spaces"
spawn_task pj5 "$PROJ1" || fail "spawn pj5 failed"$'\n'"$(cat "$TMP_ROOT/pj5.out" "$TMP_ROOT/pj5.err")"
record_worktree pj5
PJ5_PANE=$(meta_field pj5 herdr_pane_id)
PJ5_WS=$(workspace_of_pane "$PJ5_PANE")
[ "$(workspace_label "$PJ5_WS")" = "firstmate" ] || fail "with the flag absent a spawn must land in the flat 'firstmate' workspace, got '$(workspace_label "$PJ5_WS")'"
[ "$(meta_field pj5 herdr_project_space)" = "" ] || fail "a flat task must not record herdr_project_space"
pass "real herdr E2E: with the flag absent the flat per-home layout is unchanged"
teardown_task pj5 || fail "teardown pj5 failed"$'\n'"$(cat "$TMP_ROOT/pj5.td.out")"

# --- 6. a --secondmate spawn keeps per-home placement even in project mode ---

printf 'project\n' > "$HOME_DIR/config/herdr-presentation-spaces"
FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" pje2esm "$SM_HOME" "sh -c 'echo sm-ok'" --secondmate --backend herdr \
  >"$TMP_ROOT/sm.out" 2>"$TMP_ROOT/sm.err" \
  || fail "--secondmate spawn failed"$'\n'"$(cat "$TMP_ROOT/sm.out" "$TMP_ROOT/sm.err")"
SM_PANE=$(meta_field pje2esm herdr_pane_id)
SM_WS=$(workspace_of_pane "$SM_PANE")
[ "$(workspace_label "$SM_WS")" = "2ndmate-pje2esm" ] \
  || fail "a --secondmate spawn must keep its per-home '2ndmate-<id>' workspace even in project mode, got '$(workspace_label "$SM_WS")'"
[ "$(meta_field pje2esm herdr_project_space)" = "" ] || fail "a secondmate must not record herdr_project_space"
pass "real herdr E2E: a --secondmate spawn keeps its per-home placement untouched by project mode"
fm_backend_herdr_kill "$SESSION:$SM_PANE"

teardown_task pj3 || fail "teardown pj3 failed"$'\n'"$(cat "$TMP_ROOT/pj3.td.out")"
WORKTREES=()

cleanup_all
trap - EXIT
