#!/usr/bin/env bash
# tests/fm-backend-herdr-project-spaces.test.sh - unit tests for the herdr
# per-project shared-workspace layout (docs/herdr-backend.md "Project
# workspaces"): presentation-mode parsing, project journal validation, the
# adopt-or-create container ensure with every collision and fallback path, and
# fm-teardown.sh's focus-preserving close routing for herdr_project_space=1
# tasks. Follows tests/fm-backend-herdr.test.sh's fake-CLI convention, with a
# suite-local stateful fake that additionally models workspace focus (the
# focus-snapshot surface the shared statefake deliberately omits) - tests own
# their behavior-specific mocks per tests/lib.sh.
# The real-binary end-to-end proof lives in
# tests/fm-backend-herdr-project-spaces-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-project-spaces)

# --- suite-local stateful fake herdr -----------------------------------------
#
# Backed by a JSON state file ($FM_FAKE_HERDR_STATE) mutated with real jq.
# Models the verified real-herdr facts this layout depends on:
#   - workspace create seeds one default tab (label "1") and returns the seeded
#     tab/pane ids in the same response;
#   - workspace list carries focused/active_tab_id (exactly one workspace may
#     be focused), tab list carries per-tab focused;
#   - pane close removes the pane's single-pane tab, and removing a
#     workspace's LAST tab removes the workspace itself;
#   - agent get reports a preset agent_status or agent_not_found;
#   - pane get answers pane_not_found for a removed pane;
#   - session list reports one running named session with a socket_path (the
#     presentation lock path derivation input).
# Every call logs to $FM_HERDR_LOG in the shared unit-separated form.
make_project_statefake() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""; session="default"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --session) session=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}\n'
    ;;
  "session list")
    printf '{"sessions":[{"name":"%s","default":false,"running":true,"socket_path":"/tmp/fake-herdr-%s.sock"}]}\n' \
      "$session" "$session"
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    # Real-herdr fact: the very first workspace in an empty session becomes
    # focused regardless of --no-focus; later creates never steal focus.
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '((.workspaces | length) == 0) as $first
       | .workspaces += [{workspace_id:$wsid, label:$wlabel, focused:$first, active_tab_id:$tabid}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid, focused:$first}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, focused:false}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "tab get")
    tab=${3:-}
    jq_state --arg t "$tab" '{result:{tab:(.tabs[]|select(.tab_id==$t)|{tab_id:.tab_id, workspace_id:.workspace_id})}}'
    ;;
  "tab focus")
    tab=${3:-}
    jq_state --arg t "$tab" '
      (.tabs[] | select(.tab_id == $t) | .workspace_id) as $w
      | .workspaces |= [.[] | .focused = (.workspace_id == $w) | if .workspace_id == $w then .active_tab_id = $t else . end]
      | .tabs |= [.[] | .focused = (.tab_id == $t)]' | save
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane get")
    pane=${3:-}
    if jq_state -e --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length == 1' >/dev/null; then
      jq_state --arg p "$pane" '{result:{pane:(.tabs[]|select(.pane_id==$p)|{pane_id:.pane_id, tab_id:.tab_id, workspace_id:.workspace_id})}}'
    else
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$pane"
    fi
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '
      (.tabs[] | select(.pane_id == $p) | .workspace_id) as $w
      | .tabs |= [.[]|select(.pane_id != $p)]
      | if ($w != null) and (([.tabs[]|select(.workspace_id == $w)]|length) == 0)
        then .workspaces |= [.[]|select(.workspace_id != $w)]
        else . end' | save
    ;;
  "agent get")
    pane=${3:-}
    status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent %s not found"}}\n' "$pane"
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

fake_set_focus() {  # <state-file> <workspace> <tab>
  local state=$1 w=$2 t=$3 tmp="$1.tmp.$$"
  jq --arg w "$w" --arg t "$t" '
    .workspaces |= [.[] | .focused = (.workspace_id == $w) | if .workspace_id == $w then .active_tab_id = $t else . end]
    | .tabs |= [.[] | .focused = (.tab_id == $t)]' "$state" > "$tmp" && mv "$tmp" "$state"
}

fake_rename_workspace() {  # <state-file> <workspace> <new-label>
  local state=$1 w=$2 new=$3 tmp="$1.tmp.$$"
  jq --arg w "$w" --arg l "$new" \
    '.workspaces |= [.[] | if .workspace_id == $w then .label = $l else . end]' \
    "$state" > "$tmp" && mv "$tmp" "$state"
}

project_case() {  # <name> -> sets CASE_DIR, CASE_LOG, CASE_STATE, CASE_FB, CASE_HOME, CASE_PROJ
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR"
  CASE_FB=$(make_project_statefake "$CASE_DIR")
  CASE_LOG="$CASE_DIR/log"; : > "$CASE_LOG"
  CASE_STATE="$CASE_DIR/state.json"
  CASE_HOME="$CASE_DIR/home"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/config"
  CASE_PROJ="$CASE_DIR/projects/demo-app"
  mkdir -p "$CASE_PROJ"
}

run_container_ensure() {  # <state-dir> <project> [session]
  local state=$1 proj=$2 session=${3:-fmtest}
  PATH="$CASE_FB:$PATH" FM_HERDR_LOG="$CASE_LOG" FM_FAKE_HERDR_STATE="$CASE_STATE" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_project_container_ensure "$1" "$2" "$3"' \
    "$ROOT" "$session" "$state" "$proj"
}

journal_path_for() {  # <state-dir> <project>
  bash -c '. "$0/bin/backends/herdr.sh"
    p=$(fm_backend_herdr_project_identity "$2") || exit 1
    fm_backend_herdr_project_journal_path "$1" "$p"' "$ROOT" "$1" "$2"
}

journal_field() {  # <journal> <key>
  grep "^$2=" "$1" | cut -d= -f2-
}

# --- fm_backend_herdr_presentation_mode --------------------------------------

test_mode_absent_is_off() {
  local dir out
  dir="$TMP_ROOT/mode-absent"; mkdir -p "$dir"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_mode "$1"' "$ROOT" "$dir")
  [ "$out" = off ] || fail "an absent flag file should resolve to off, got '$out'"
  pass "presentation_mode: absent file resolves to off (flat layout)"
}

test_mode_empty_file_is_task() {
  local dir out
  dir="$TMP_ROOT/mode-empty"; mkdir -p "$dir"
  : > "$dir/herdr-presentation-spaces"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_mode "$1"' "$ROOT" "$dir")
  [ "$out" = task ] || fail "an empty flag file (the original presence semantics) should resolve to task, got '$out'"
  pass "presentation_mode: an empty flag file keeps the per-task projection byte-identically"
}

test_mode_task_and_project_values() {
  local dir out
  dir="$TMP_ROOT/mode-values"; mkdir -p "$dir"
  printf 'task\n' > "$dir/herdr-presentation-spaces"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_mode "$1"' "$ROOT" "$dir")
  [ "$out" = task ] || fail "'task' should resolve to task, got '$out'"
  printf '\n\n  project  \n' > "$dir/herdr-presentation-spaces"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_mode "$1"' "$ROOT" "$dir")
  [ "$out" = project ] || fail "a whitespace-padded 'project' first non-empty line should resolve to project, got '$out'"
  pass "presentation_mode: task and project values parse from the first non-empty trimmed line"
}

test_mode_unknown_value_warns_and_is_task() {
  local dir out err
  dir="$TMP_ROOT/mode-unknown"; mkdir -p "$dir"
  printf 'projct\n' > "$dir/herdr-presentation-spaces"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_mode "$1"' "$ROOT" "$dir" 2>"$dir/err")
  err=$(cat "$dir/err")
  [ "$out" = task ] || fail "an unrecognized value must preserve the presence semantics (task), got '$out'"
  assert_contains "$err" "unrecognized herdr-presentation-spaces value 'projct'" \
    "an unrecognized value should warn with the offending value"
  pass "presentation_mode: an unrecognized value warns loudly and keeps the per-task layout, never flat"
}

# --- project journal write/snapshot ------------------------------------------

test_project_journal_roundtrip() {
  local dir journal token out
  dir="$TMP_ROOT/journal-roundtrip"; mkdir -p "$dir/state" "$dir/proj"
  token=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_id' "$ROOT")
  out=$(bash -c '. "$0/bin/backends/herdr.sh"
    proj=$(fm_backend_herdr_project_identity "$1/proj") || exit 1
    journal=$(fm_backend_herdr_project_journal_path "$1/state" "$proj") || exit 1
    label=$(fm_backend_herdr_project_workspace_label "$proj" "$2")
    fm_backend_herdr_project_journal_write "$journal" "$proj" fmtest "$2" "$label" || exit 1
    fm_backend_herdr_project_journal_snapshot "$journal" "$proj" || exit 2
    [ "$FM_BACKEND_HERDR_PROJECT_JOURNAL_VERSION" = 1 ] || exit 3
    fm_backend_herdr_project_journal_write "$journal" "$proj" fmtest "$2" "$label" w42 || exit 4
    fm_backend_herdr_project_journal_snapshot "$journal" "$proj" || exit 5
    [ "$FM_BACKEND_HERDR_PROJECT_JOURNAL_VERSION" = 2 ] || exit 6
    [ "$FM_BACKEND_HERDR_PROJECT_JOURNAL_WORKSPACE_ID" = w42 ] || exit 7
    [ "$FM_BACKEND_HERDR_PROJECT_JOURNAL_PROJECTION_ID" = "$2" ] || exit 8
    printf ok' "$ROOT" "$dir" "$token")
  [ "$out" = ok ] || fail "project journal v1 write, v2 bind, and snapshot should round-trip (marker '$out')"
  pass "project journal: version 1 attempt and version 2 binding round-trip through strict snapshot validation"
}

test_project_journal_rejects_tampering() {
  local dir journal token
  dir="$TMP_ROOT/journal-tamper"; mkdir -p "$dir/state" "$dir/proj" "$dir/other"
  token=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_id' "$ROOT")
  journal=$(bash -c '. "$0/bin/backends/herdr.sh"
    proj=$(fm_backend_herdr_project_identity "$1/proj") || exit 1
    j=$(fm_backend_herdr_project_journal_path "$1/state" "$proj") || exit 1
    label=$(fm_backend_herdr_project_workspace_label "$proj" "$2")
    fm_backend_herdr_project_journal_write "$j" "$proj" fmtest "$2" "$label" w42 || exit 1
    printf %s "$j"' "$ROOT" "$dir" "$token")
  [ -n "$journal" ] || fail "could not build the tamper fixture journal"

  snapshot_status() {  # <project-dir>
    bash -c '. "$0/bin/backends/herdr.sh"
      proj=$(fm_backend_herdr_project_identity "$2") || exit 9
      fm_backend_herdr_project_journal_snapshot "$1" "$proj"' "$ROOT" "$journal" "$1"
  }

  snapshot_status "$dir/proj" || fail "the untampered journal should validate"
  snapshot_status "$dir/other" && fail "a journal for a different project path must not validate"

  sed -i.bak 's/^label=.*/label=renamed · p:AAAAAAAAAAAAAAAAAAAAAA/' "$journal" && rm -f "$journal.bak"
  snapshot_status "$dir/proj" && fail "a journal whose label does not recompute from project+token must not validate"

  printf 'version=2\n' >> "$journal"
  snapshot_status "$dir/proj" && fail "a journal with duplicate keys or a wrong line count must not validate"

  rm -f "$journal"
  printf 'garbage\n' > "$dir/state/garbage-journal"
  bash -c '. "$0/bin/backends/herdr.sh"
    proj=$(fm_backend_herdr_project_identity "$2") || exit 9
    fm_backend_herdr_project_journal_snapshot "$1" "$proj"' "$ROOT" "$dir/state/garbage-journal" "$dir/proj" \
    && fail "a malformed journal must not validate"
  pass "project journal: wrong project, tampered label, duplicated keys, and garbage all fail strict validation"
}

# --- fm_backend_herdr_project_container_ensure -------------------------------

test_project_ensure_creates_fresh_workspace_in_empty_session() {
  local out rc journal token label wsid seeded
  project_case ensure-fresh
  out=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>"$CASE_DIR/err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "fresh project container ensure should succeed (rc=$rc): $(cat "$CASE_DIR/err")"
  journal=$(journal_path_for "$CASE_HOME/state" "$CASE_PROJ")
  [ -f "$journal" ] || fail "no project journal written at $journal"
  token=$(journal_field "$journal" projection_id)
  label=$(journal_field "$journal" label)
  wsid=$(journal_field "$journal" workspace_id)
  [ "$(journal_field "$journal" version)" = 2 ] || fail "the successful create should bind a version 2 journal"
  [ "$label" = "demo-app · p:$token" ] || fail "workspace label should be '<basename> · p:<token>', got '$label'"
  case "$out" in
    "fmtest:$wsid"$'\t'*) : ;;
    *) fail "container echo should be 'fmtest:$wsid\\t<seeded>', got '$out'" ;;
  esac
  seeded=${out#*$'\t'}
  [ -n "$seeded" ] || fail "a CREATED project workspace must echo its seeded default tab id"
  jq -e --arg id "$wsid" --arg l "$label" \
    '[.workspaces[]|select(.workspace_id==$id and .label==$l)]|length == 1' "$CASE_STATE" >/dev/null \
    || fail "the created workspace is not live with the journal's exact label"
  pass "project container ensure: first spawn creates '<project> · p:<token>', binds v2, echoes the seeded tab id"
}

test_project_ensure_adopts_exact_bound_workspace() {
  local out1 out2 rc wsid seeded
  project_case ensure-adopt
  out1=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>/dev/null) || fail "setup create failed"
  wsid=${out1%%$'\t'*}; wsid=${wsid#fmtest:}
  : > "$CASE_LOG"
  out2=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>"$CASE_DIR/err2")
  rc=$?
  [ "$rc" -eq 0 ] || fail "second ensure should adopt (rc=$rc): $(cat "$CASE_DIR/err2")"
  case "$out2" in
    "fmtest:$wsid"$'\t') : ;;
    *) fail "adoption should echo the SAME workspace with an EMPTY seeded field, got '$out2'" ;;
  esac
  seeded=${out2#*$'\t'}
  [ -z "$seeded" ] || fail "an ADOPTED workspace must never carry a seeded tab id (prune gate), got '$seeded'"
  assert_not_contains "$(cat "$CASE_LOG")" $'\x1f''workspace'$'\x1f''create' \
    "adoption must not create a second workspace"
  pass "project container ensure: a later spawn adopts the exact bound workspace with no seeded prune authority"
}

test_project_ensure_recreates_when_workspace_gone() {
  local out1 out2 rc wsid1 wsid2 journal token1 token2
  project_case ensure-gone
  out1=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>/dev/null) || fail "setup create failed"
  wsid1=${out1%%$'\t'*}; wsid1=${wsid1#fmtest:}
  journal=$(journal_path_for "$CASE_HOME/state" "$CASE_PROJ")
  token1=$(journal_field "$journal" projection_id)
  # Simulate the workspace's last tab closing (herdr removes the workspace).
  printf '{"next":50,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$CASE_STATE"
  out2=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>"$CASE_DIR/err2")
  rc=$?
  [ "$rc" -eq 0 ] || fail "ensure after workspace removal should recreate (rc=$rc): $(cat "$CASE_DIR/err2")"
  wsid2=${out2%%$'\t'*}; wsid2=${wsid2#fmtest:}
  token2=$(journal_field "$journal" projection_id)
  [ "$wsid2" != "$wsid1" ] || fail "a recreated workspace should have a fresh id"
  [ "$token2" != "$token1" ] || fail "a recreated workspace must mint a NEW token, never reuse the old one"
  [ "$(journal_field "$journal" workspace_id)" = "$wsid2" ] || fail "the journal should rebind to the new workspace"
  pass "project container ensure: a legitimately-gone workspace is recreated with a fresh token and rebound"
}

test_project_ensure_renamed_label_falls_back_flat() {
  local out1 out2 rc err wsid journal before after
  project_case ensure-renamed
  out1=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>/dev/null) || fail "setup create failed"
  wsid=${out1%%$'\t'*}; wsid=${wsid#fmtest:}
  journal=$(journal_path_for "$CASE_HOME/state" "$CASE_PROJ")
  before=$(cat "$journal")
  fake_rename_workspace "$CASE_STATE" "$wsid" "captain renamed me"
  : > "$CASE_LOG"
  out2=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>"$CASE_DIR/err2")
  rc=$?
  err=$(cat "$CASE_DIR/err2")
  [ "$rc" -eq 2 ] || fail "a renamed recorded workspace must return 2 (fall back flat), got rc=$rc out='$out2'"
  assert_contains "$err" "not provably firstmate's own container" \
    "the renamed-label fallback should say the container is not provably firstmate's own"
  after=$(cat "$journal")
  [ "$before" = "$after" ] || fail "the fallback must not touch the journal"
  assert_not_contains "$(cat "$CASE_LOG")" $'\x1f''workspace'$'\x1f''create' \
    "the renamed-label fallback must not create another workspace"
  assert_not_contains "$(cat "$CASE_LOG")" $'\x1f''pane'$'\x1f''close' \
    "the renamed-label fallback must not close anything"
  pass "project container ensure: a renamed recorded workspace falls back flat loudly, touching nothing"
}

test_project_ensure_duplicated_token_falls_back_flat() {
  local out1 out2 rc err wsid journal token
  project_case ensure-dup-token
  out1=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>/dev/null) || fail "setup create failed"
  wsid=${out1%%$'\t'*}; wsid=${wsid#fmtest:}
  journal=$(journal_path_for "$CASE_HOME/state" "$CASE_PROJ")
  token=$(journal_field "$journal" projection_id)
  # A second workspace carrying the same token suffix makes adoption ambiguous.
  jq --arg l "impostor · p:$token" \
    '.workspaces += [{workspace_id:"w99", label:$l, focused:false, active_tab_id:"w99:t99"}]
     | .tabs += [{tab_id:"w99:t99", label:"1", workspace_id:"w99", pane_id:"w99:p99", focused:false}]' \
    "$CASE_STATE" > "$CASE_STATE.tmp" && mv "$CASE_STATE.tmp" "$CASE_STATE"
  out2=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>"$CASE_DIR/err2")
  rc=$?
  err=$(cat "$CASE_DIR/err2")
  [ "$rc" -eq 2 ] || fail "a duplicated token suffix must return 2 (fall back flat), got rc=$rc out='$out2'"
  assert_contains "$err" "not provably firstmate's own container" \
    "the duplicated-token fallback should warn about provability"
  pass "project container ensure: a duplicated token suffix is ambiguous and falls back flat loudly"
}

test_project_ensure_v1_journal_warns_and_creates_fresh() {
  local out rc err journal token1 token2
  project_case ensure-v1
  # A version 1 journal is a create attempt that never bound (a crash).
  token1=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_projection_id' "$ROOT")
  bash -c '. "$0/bin/backends/herdr.sh"
    proj=$(fm_backend_herdr_project_identity "$2") || exit 1
    j=$(fm_backend_herdr_project_journal_path "$1" "$proj") || exit 1
    label=$(fm_backend_herdr_project_workspace_label "$proj" "$3")
    fm_backend_herdr_project_journal_write "$j" "$proj" fmtest "$3" "$label"' \
    "$ROOT" "$CASE_HOME/state" "$CASE_PROJ" "$token1" || fail "could not write the v1 fixture journal"
  out=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>"$CASE_DIR/err")
  rc=$?
  err=$(cat "$CASE_DIR/err")
  [ "$rc" -eq 0 ] || fail "a v1 journal should warn and create fresh (rc=$rc): $err"
  assert_contains "$err" "unbound create attempt" \
    "the v1-journal path should warn about the possible orphan workspace"
  journal=$(journal_path_for "$CASE_HOME/state" "$CASE_PROJ")
  token2=$(journal_field "$journal" projection_id)
  [ "$token2" != "$token1" ] || fail "the fresh create must mint a new token, never adopt the crashed attempt's"
  [ "$(journal_field "$journal" version)" = 2 ] || fail "the fresh create should bind version 2"
  pass "project container ensure: a crashed (version 1) attempt warns about the orphan and creates fresh"
}

test_project_ensure_malformed_journal_falls_back_flat_preserving_it() {
  local out rc err journal
  project_case ensure-malformed
  journal=$(journal_path_for "$CASE_HOME/state" "$CASE_PROJ")
  mkdir -p "$(dirname "$journal")"
  printf 'not a journal\n' > "$journal"
  out=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>"$CASE_DIR/err")
  rc=$?
  err=$(cat "$CASE_DIR/err")
  [ "$rc" -eq 2 ] || fail "a malformed journal must return 2 (fall back flat), got rc=$rc out='$out'"
  assert_contains "$err" "malformed herdr project workspace journal" \
    "the malformed-journal fallback should name the problem"
  [ "$(cat "$journal")" = "not a journal" ] || fail "the malformed journal must be preserved for inspection"
  pass "project container ensure: a malformed journal falls back flat loudly and is preserved"
}

test_project_ensure_other_session_journal_creates_here() {
  local out rc journal
  project_case ensure-other-session
  out=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" othersession 2>/dev/null) \
    || fail "setup create in the other session failed"
  : > "$CASE_LOG"
  out=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" fmtest 2>"$CASE_DIR/err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a journal bound to another named session should warn and create here (rc=$rc): $(cat "$CASE_DIR/err")"
  assert_contains "$(cat "$CASE_DIR/err")" "binds a different named session" \
    "the cross-session path should warn before creating fresh"
  journal=$(journal_path_for "$CASE_HOME/state" "$CASE_PROJ")
  [ "$(journal_field "$journal" session)" = fmtest ] || fail "the journal should rebind to the current session"
  pass "project container ensure: a journal bound to another named session warns and creates fresh here"
}

test_project_ensure_distinct_projects_get_distinct_workspaces() {
  local proj2 out1 out2 ws1 ws2
  project_case ensure-two-projects
  proj2="$CASE_DIR/projects/other-app"; mkdir -p "$proj2"
  out1=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>/dev/null) || fail "project 1 create failed"
  out2=$(run_container_ensure "$CASE_HOME/state" "$proj2" 2>/dev/null) || fail "project 2 create failed"
  ws1=${out1%%$'\t'*}
  ws2=${out2%%$'\t'*}
  [ "$ws1" != "$ws2" ] || fail "two different projects must resolve to two different workspaces, both got '$ws1'"
  jq -e '[.workspaces[]|select(.label|startswith("demo-app · p:"))]|length == 1' "$CASE_STATE" >/dev/null \
    || fail "demo-app workspace missing"
  jq -e '[.workspaces[]|select(.label|startswith("other-app · p:"))]|length == 1' "$CASE_STATE" >/dev/null \
    || fail "other-app workspace missing"
  pass "project container ensure: different projects land in different project-named workspaces"
}

test_project_ensure_preserves_focus_on_create() {
  local out rc
  project_case ensure-focus
  # A captain-focused workspace exists before the project create.
  jq '.workspaces += [{workspace_id:"wcap", label:"captain", focused:true, active_tab_id:"wcap:t1"}]
      | .tabs += [{tab_id:"wcap:t1", label:"main", workspace_id:"wcap", pane_id:"wcap:p1", focused:true}]' \
    "$CASE_STATE" > "$CASE_STATE.tmp" && mv "$CASE_STATE.tmp" "$CASE_STATE"
  out=$(run_container_ensure "$CASE_HOME/state" "$CASE_PROJ" 2>"$CASE_DIR/err")
  rc=$?
  [ "$rc" -eq 0 ] || fail "create with an existing focused workspace should succeed (rc=$rc): $(cat "$CASE_DIR/err")"
  jq -e '[.workspaces[]|select(.focused == true)][0].workspace_id == "wcap"' "$CASE_STATE" >/dev/null \
    || fail "the captain's focused workspace must remain focused after the project create"
  pass "project container ensure: creating the project workspace preserves the captain's exact focus"
}

# --- fm-teardown.sh routing for herdr_project_space=1 ------------------------

make_teardown_case() {  # <name> -> sets TD_DIR, TD_FB, TD_LOG, TD_STATE, TD_HOME
  local name=$1
  TD_DIR="$TMP_ROOT/$name"
  mkdir -p "$TD_DIR"
  TD_FB=$(make_project_statefake "$TD_DIR")
  TD_LOG="$TD_DIR/log"; : > "$TD_LOG"
  TD_STATE="$TD_DIR/state.json"
  TD_HOME="$TD_DIR/home"
  mkdir -p "$TD_HOME/state" "$TD_HOME/data" "$TD_HOME/config" "$TD_DIR/worktree" "$TD_DIR/project"
  cat > "$TD_FB/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$TD_FB/treehouse"
}

seed_teardown_task() {  # <id> <with-project-flag 0|1>
  local id=$1 flagged=$2 extra=()
  # One captain-focused workspace plus the task's own project workspace with
  # the task tab AND a captain dev-server tab alongside it.
  jq '.workspaces = [
        {workspace_id:"wcap", label:"captain", focused:true, active_tab_id:"wcap:t1"},
        {workspace_id:"wproj", label:"demo-app · p:AAAAAAAAAAAAAAAAAAAAAA", focused:false, active_tab_id:"wproj:t2"}
      ]
      | .tabs = [
        {tab_id:"wcap:t1", label:"main", workspace_id:"wcap", pane_id:"wcap:p1", focused:true},
        {tab_id:"wproj:t2", label:"devserver", workspace_id:"wproj", pane_id:"wproj:p2", focused:false},
        {tab_id:"wproj:t3", label:"fm-'"$id"'", workspace_id:"wproj", pane_id:"wproj:p3", focused:false}
      ]' "$TD_STATE" > "$TD_STATE.tmp" && mv "$TD_STATE.tmp" "$TD_STATE"
  [ "$flagged" != 1 ] || extra+=("herdr_project_space=1")
  fm_write_meta "$TD_HOME/state/$id.meta" \
    "window=fmtest:wproj:p3" "endpoint_task_id=$id" \
    "worktree=$TD_DIR/worktree" "project=$TD_DIR/project" \
    "kind=scout" "backend=herdr" \
    "herdr_session=fmtest" "herdr_workspace_id=wproj" \
    "herdr_tab_id=wproj:t3" "herdr_pane_id=wproj:p3" \
    ${extra[0]:+"${extra[@]}"}
}

run_teardown() {  # <id>
  FM_HOME="$TD_HOME" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION=fmtest \
  FM_HERDR_LOG="$TD_LOG" FM_FAKE_HERDR_STATE="$TD_STATE" PATH="$TD_FB:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$1" --force
}

test_teardown_project_space_closes_exact_pane_focus_preservingly() {
  local id=projtask out rc
  make_teardown_case teardown-project
  seed_teardown_task "$id" 1
  out=$(run_teardown "$id" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "teardown should succeed (rc=$rc): $out"
  assert_not_contains "$out" "could not be confirmed" "the exact-pane close should be confirmed dead"
  jq -e '[.tabs[]|select(.pane_id=="wproj:p3")]|length == 0' "$TD_STATE" >/dev/null \
    || fail "the task pane was not closed"
  jq -e '[.tabs[]|select(.pane_id=="wproj:p2")]|length == 1' "$TD_STATE" >/dev/null \
    || fail "the captain's dev-server tab in the SAME workspace must survive the task teardown"
  jq -e '[.workspaces[]|select(.workspace_id=="wproj")]|length == 1' "$TD_STATE" >/dev/null \
    || fail "the shared project workspace must survive while it still holds other tabs"
  jq -e '[.workspaces[]|select(.focused == true)][0].workspace_id == "wcap"' "$TD_STATE" >/dev/null \
    || fail "the captain's focus must be preserved across the projected close"
  assert_contains "$(cat "$TD_LOG")" $'\x1f''workspace'$'\x1f''list' \
    "the flagged task's close must route through the focus-preserving path (focus snapshot first)"
  [ ! -f "$TD_HOME/state/$id.meta" ] || fail "teardown did not remove the task meta"
  pass "teardown: herdr_project_space=1 closes only the exact pane via the focus-preserving path; captain tabs and the workspace survive"
}

test_teardown_without_flag_uses_plain_kill() {
  local id=flattask out rc
  make_teardown_case teardown-flat
  seed_teardown_task "$id" 0
  out=$(run_teardown "$id" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "teardown should succeed (rc=$rc): $out"
  jq -e '[.tabs[]|select(.pane_id=="wproj:p3")]|length == 0' "$TD_STATE" >/dev/null \
    || fail "the task pane was not closed"
  assert_not_contains "$(cat "$TD_LOG")" $'\x1f''workspace'$'\x1f''list' \
    "an unflagged herdr task must keep the plain exact-pane kill path (no focus choreography)"
  pass "teardown: without herdr_project_space the existing plain kill path is byte-identical"
}

test_teardown_project_space_refuses_active_tab_close() {
  local id=activetask out rc
  make_teardown_case teardown-active
  seed_teardown_task "$id" 1
  # The captain is looking AT the task tab: closing it cannot preserve focus.
  fake_set_focus "$TD_STATE" wproj wproj:t3
  out=$(run_teardown "$id" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "teardown should still complete (rc=$rc): $out"
  assert_contains "$out" "could not be confirmed" \
    "an active-tab target should be refused and reported, not silently closed"
  jq -e '[.tabs[]|select(.pane_id=="wproj:p3")]|length == 1' "$TD_STATE" >/dev/null \
    || fail "the active task tab must NOT be closed when focus cannot be preserved"
  pass "teardown: a project-space close that cannot preserve focus is refused and reported, never forced"
}

test_mode_absent_is_off
test_mode_empty_file_is_task
test_mode_task_and_project_values
test_mode_unknown_value_warns_and_is_task
test_project_journal_roundtrip
test_project_journal_rejects_tampering
test_project_ensure_creates_fresh_workspace_in_empty_session
test_project_ensure_adopts_exact_bound_workspace
test_project_ensure_recreates_when_workspace_gone
test_project_ensure_renamed_label_falls_back_flat
test_project_ensure_duplicated_token_falls_back_flat
test_project_ensure_v1_journal_warns_and_creates_fresh
test_project_ensure_malformed_journal_falls_back_flat_preserving_it
test_project_ensure_other_session_journal_creates_here
test_project_ensure_distinct_projects_get_distinct_workspaces
test_project_ensure_preserves_focus_on_create
test_teardown_project_space_closes_exact_pane_focus_preservingly
test_teardown_without_flag_uses_plain_kill
test_teardown_project_space_refuses_active_tab_close

echo "all fm-backend-herdr-project-spaces tests passed"
