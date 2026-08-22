#!/usr/bin/env bash
# Behavior tests for bin/fm-proof.sh, the ship-task proof contract.
#
# The property under test is the one that makes the gate more than decorative:
# four outcomes, not two. A demonstrable task refuses without durable evidence;
# an explicitly non-demonstrable one passes in silence; a waived one passes but
# keeps announcing itself; and a task that declared NOTHING is distinguishable
# from all three. Collapse the last case into either neighbour and the gate
# either wedges live work or lets silence read as an attestation.
#
# Everything here drives the executable. bin/fm-teardown.sh's own suite covers
# the same contract through the real teardown path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-proof.sh"
TMP_ROOT=$(fm_test_tmproot fm-proof)

# One task in a fresh sandbox home. Args: <id> [meta key=value...]
make_task() {
  local id=$1 home; shift
  home="$TMP_ROOT/$id"
  mkdir -p "$home/state" "$home/data/$id"
  fm_write_meta "$home/state/$id.meta" "kind=ship" "mode=no-mistakes" "$@"
  printf '%s\n' "$home"
}

# Run a fm-proof.sh command against a sandbox home. Args: <home> <args...>
run_proof() {
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROOF" "$@"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$PROOF" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-proof.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-proof.sh emitted unexpected output: $out"
  pass "fm-proof.sh: bash -n succeeds"
}

test_help_renders_the_header() {
  local help
  help=$("$PROOF" --help)
  assert_contains "$help" "fm-proof.sh verify <task-id>" "fm-proof.sh --help omitted its usage"
  assert_contains "$help" "data/<task-id>/proof/" "fm-proof.sh --help omitted the bundle location"
  pass "fm-proof.sh: --help renders the contract header"
}

# The refusal has to be actionable on its own: what was promised, where it
# belongs, and every honest way out. A worker or firstmate reading only stderr
# must not have to go and read the script.
test_demonstrable_without_a_bundle_refuses_with_a_complete_remedy() {
  local home out rc
  home=$(make_task task-refuse "proof=demonstrable" \
    "proof_declaration=the subject search returns hangtag rows against the live corpus")

  set +e
  out=$(run_proof "$home" verify task-refuse 2>&1); rc=$?
  set -e

  expect_code 1 "$rc" "a demonstrable task with no bundle was allowed through"
  assert_contains "$out" "the subject search returns hangtag rows" \
    "refusal did not name what was declared at intake"
  assert_contains "$out" "$home/data/task-refuse/proof" \
    "refusal did not name where the evidence belongs"
  assert_contains "$out" "capture, not a new verification pass" \
    "refusal did not frame the remedy as capture rather than more checking"
  assert_contains "$out" "fm-proof.sh waive task-refuse" \
    "refusal did not offer the honest late answer"
  assert_contains "$out" "explicit captain authority to discard" \
    "refusal did not qualify the force path"
  pass "fm-proof.sh: a demonstrable task with no surviving proof refuses with a complete remedy"
}

test_demonstrable_with_a_bundle_passes() {
  local home out rc
  home=$(make_task task-pass "proof=demonstrable" "proof_declaration=the export downloads")
  mkdir -p "$home/data/task-pass/proof"
  printf 'transcript\n' > "$home/data/task-pass/proof/notes.md"

  set +e
  out=$(run_proof "$home" verify task-pass 2>&1); rc=$?
  set -e

  expect_code 0 "$rc" "a demonstrable task with durable proof was refused"
  assert_contains "$out" "proof bundle at $home/data/task-pass/proof" \
    "the pass did not report where the evidence was found"
  pass "fm-proof.sh: a demonstrable task passes once its evidence is durable"
}

# Non-empty is the test, not existence. `find -size +0` counts 512-byte blocks
# on BSD, so a byte-sized check is what keeps an empty placeholder out.
test_an_empty_file_is_not_evidence() {
  local home rc
  home=$(make_task task-empty "proof=demonstrable" "proof_declaration=the chart renders")
  mkdir -p "$home/data/task-empty/proof/nested"
  : > "$home/data/task-empty/proof/nested/screenshot.png"

  set +e
  run_proof "$home" verify task-empty >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" "an empty placeholder file satisfied the gate"

  printf 'x\n' > "$home/data/task-empty/proof/nested/screenshot.png"
  set +e
  run_proof "$home" verify task-empty >/dev/null 2>&1; rc=$?
  set -e
  expect_code 0 "$rc" "a non-empty file nested in the bundle did not satisfy the gate"
  pass "fm-proof.sh: only a non-empty file counts, at any depth in the bundle"
}

# Forcing artifacts onto a refactor or a docs fix trains every reader to skim
# the evidence, so the attestation must cost nothing and say nothing.
test_non_demonstrable_passes_without_artifacts_or_noise() {
  local home out rc err
  home=$(make_task task-none "proof=none" \
    "proof_declaration=internal lint configuration with no user-visible surface")

  set +e
  out=$(run_proof "$home" verify task-none 2>"$home/err"); rc=$?
  set -e
  err=$(cat "$home/err")

  expect_code 0 "$rc" "an explicit non-demonstrable attestation was refused"
  [ -z "$err" ] || fail "a clean attestation produced warning noise: $err"
  assert_contains "$out" "declared not demonstrable" "the pass did not record why nothing was required"
  assert_absent "$home/data/task-none/proof" "the attestation path expected a bundle anyway"
  pass "fm-proof.sh: an explicit non-demonstrable attestation passes with no artifacts and no noise"
}

# THE property that keeps the gate honest. Nobody declaring anything must not
# wedge in-flight work, but it must also never read as the attestation above.
test_silence_is_not_an_attestation() {
  local home undeclared_err attested_err rc
  home=$(make_task task-silent)

  set +e
  run_proof "$home" verify task-silent >/dev/null 2>"$home/undeclared-err"; rc=$?
  set -e
  expect_code 0 "$rc" "a task predating the gate was wedged instead of grandfathered"
  undeclared_err=$(cat "$home/undeclared-err")
  [ -n "$undeclared_err" ] || fail "an undeclared task passed as silently as an explicit attestation"
  assert_contains "$undeclared_err" "no proof declaration" \
    "the grandfather warning did not say what was missing"

  fm_write_meta "$home/state/task-silent.meta" "kind=ship" "proof=none" "proof_declaration=nothing to show"
  run_proof "$home" verify task-silent >/dev/null 2>"$home/attested-err"
  attested_err=$(cat "$home/attested-err")
  [ -z "$attested_err" ] || fail "an explicit attestation warned like an undeclared task: $attested_err"

  assert_contains "$(run_proof "$home" show task-silent)" "none for task-silent" \
    "show did not distinguish an attestation"
  pass "fm-proof.sh: an undeclared task is grandfathered loudly and never reads as an attestation"
}

# A record this script cannot read is not evidence that the proof exists.
test_an_unreadable_declaration_fails_closed() {
  local home out rc
  home=$(make_task task-garbled "proof=probably" "proof_declaration=who knows")

  set +e
  out=$(run_proof "$home" verify task-garbled 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "an unrecognized proof value was treated as a pass"
  assert_contains "$out" "unrecognized proof declaration" "the refusal did not name the corrupt record"
  pass "fm-proof.sh: an unrecognized proof record fails closed"
}

# The waiver is the honest late answer, so it must be recorded, reasoned, and
# permanently visible - never a quiet conversion into "not demonstrable".
test_waiver_is_recorded_reasoned_and_still_announced() {
  local home out rc
  home=$(make_task task-waive "proof=demonstrable" "proof_declaration=the invoice PDF opens")

  set +e
  out=$(run_proof "$home" waive task-waive 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "a waiver was accepted with no reason"
  assert_contains "$out" "requires --reason" "the reasonless waiver did not explain itself"

  run_proof "$home" waive task-waive --reason "scope narrowed to an internal script mid-flight" \
    >/dev/null 2>&1 || fail "a reasoned waiver was refused"

  set +e
  out=$(run_proof "$home" verify task-waive 2>&1); rc=$?
  set -e
  expect_code 0 "$rc" "a recorded waiver did not let verify pass"
  assert_contains "$out" "scope narrowed to an internal script mid-flight" \
    "the waiver passed without re-announcing its reason"
  assert_contains "$(run_proof "$home" show task-waive)" "waived for task-waive" \
    "show reported a waived task as something else"
  pass "fm-proof.sh: a waiver needs a reason, is recorded durably, and keeps announcing itself"
}

# A task that already attested it is not demonstrable has nothing to waive, and
# letting it be re-labelled would only blur two different honest answers.
test_waiver_is_refused_on_an_attested_task() {
  local home out rc
  home=$(make_task task-none-waive "proof=none" "proof_declaration=docs only")

  set +e
  out=$(run_proof "$home" waive task-none-waive --reason "changed my mind" 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "an already-attested task accepted a waiver"
  assert_contains "$out" "already attested" "the refusal did not explain the overlap"
  pass "fm-proof.sh: an explicitly non-demonstrable task cannot be re-labelled as waived"
}

# show is what bin/fm-pr-check.sh hands the captain beside the PR link, so it
# must be honest while the evidence is still missing.
test_show_reports_a_declared_but_uncaptured_task() {
  local home out
  home=$(make_task task-show "proof=demonstrable" "proof_declaration=the banner disappears")
  out=$(run_proof "$home" show task-show)
  assert_contains "$out" "not yet captured" "show claimed evidence that does not exist"
  assert_contains "$out" "the banner disappears" "show dropped the declaration"

  mkdir -p "$home/data/task-show/proof"
  printf 'shot\n' > "$home/data/task-show/proof/after.png"
  out=$(run_proof "$home" show task-show)
  assert_contains "$out" "$home/data/task-show/proof (1 file)" \
    "show did not hand over the durable bundle path once it existed"
  pass "fm-proof.sh: show hands over the bundle only once it actually exists"
}

test_unknown_inputs_are_refused() {
  local rc home
  home=$(make_task task-args "proof=none" "proof_declaration=nothing")
  set +e
  run_proof "$home" verify >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "verify with no task id did not report a usage error"
  run_proof "$home" nonsense task-args >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown subcommand did not report a usage error"
  run_proof "$home" verify ../escape >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a path-traversing task id was not rejected"
  run_proof "$home" verify task-absent >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a task with no metadata was not reported"
  set -e
  pass "fm-proof.sh: malformed invocations and unknown tasks are refused, never assumed"
}

# --- intake recording, through a spawn that actually completes ---------------
#
# The declaration reaching state/<id>.meta is what every later gate reads, so
# these drive the real bin/fm-spawn.sh against a fake tmux rather than writing
# the record by hand.

SPAWN="$ROOT/bin/fm-spawn.sh"

make_spawn_case() {  # <name> [proof-contract] [declaration]
  local name=$1 proof=${2:-} declaration=${3:-} case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="proofspawn-$name"
  mkdir -p "$home/data/$id"
  # A brief scaffolded before this gate existed carries no proof section at all -
  # bin/fm-brief.sh only began rendering one with the gate - so the grandfathered
  # case must not be handed a section header it could never have had.
  {
    printf 'You are a crewmate.\n\n'
    if [ -n "$proof" ] || [ -n "$declaration" ]; then
      printf '# Proof of what shipped\n'
      [ -z "$proof" ] || printf 'Proof contract: %s\n' "$proof"
      [ -z "$declaration" ] || printf 'Proof declaration: %s\n' "$declaration"
    fi
    printf '\n# Definition of done\nDelivery contract: mode=no-mistakes\n'
  } > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$id"
}

run_spawn_case() {  # <home> <wt> <fakebin> <spawn args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_records_the_declaration_into_the_task_record() {
  local rec home proj wt fakebin id
  rec=$(make_spawn_case demonstrable demonstrable 'the invoice list stops showing duplicates')
  IFS='|' read -r home proj wt fakebin id <<EOF
$rec
EOF
  run_spawn_case "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off >/dev/null \
    || fail "the spawn did not complete"
  assert_grep 'proof=demonstrable' "$home/state/$id.meta" \
    "the spawn did not record the brief's proof contract"
  assert_grep 'proof_declaration=the invoice list stops showing duplicates' "$home/state/$id.meta" \
    "the spawn did not record the declaration verbatim"
  [ "$(grep -c '^proof=' "$home/state/$id.meta")" = 1 ] \
    || fail "the spawn wrote more than one proof= line"
  pass "fm-spawn: a fresh ship spawn records the brief's declaration in the task record"
}

test_spawn_records_an_attestation_and_records_nothing_when_none_was_declared() {
  local rec home proj wt fakebin id
  rec=$(make_spawn_case attested none 'internal script with no user-visible surface')
  IFS='|' read -r home proj wt fakebin id <<EOF
$rec
EOF
  run_spawn_case "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off >/dev/null \
    || fail "the attested spawn did not complete"
  assert_grep 'proof=none' "$home/state/$id.meta" "the spawn did not record the attestation"

  rec=$(make_spawn_case grandfathered)
  IFS='|' read -r home proj wt fakebin id <<EOF
$rec
EOF
  run_spawn_case "$home" "$wt" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off >/dev/null \
    || fail "the grandfathered spawn did not complete"
  assert_no_grep 'proof=' "$home/state/$id.meta" \
    "the spawn invented a proof record for a brief that declared none"
  pass "fm-spawn: an attestation is recorded, and a brief declaring nothing records nothing"
}


# --- delivery: the proof reaches the captain WITH the PR link ---------------
#
# The captain having to say "show me proof" after a PR lands is the delivery
# half of the same failure the gate closes, and arming the merge poll is the one
# moment firstmate holds both the PR URL and the task id.
test_pr_check_hands_the_proof_over_with_the_link() {
  local case_dir out
  case_dir="$TMP_ROOT/pr-check"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data/task-a/proof" "$case_dir/fakebin"
  fm_write_meta "$case_dir/home/state/task-a.meta" \
    "window=fm-task-a" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "proof=demonstrable" \
    "proof_declaration=the invoice list stops showing duplicates"
  printf 'after\n' > "$case_dir/home/data/task-a/proof/after.png"
  fm_fake_exit0 "$case_dir/fakebin" gh
  fm_fake_exit0 "$case_dir/fakebin" gh-axi

  out=$(FM_HOME="$case_dir/home" FM_SPAWN_NO_GUARD=1 PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-a https://github.com/o/r/pull/7 2>/dev/null)
  assert_contains "$out" "armed: state/task-a.check.sh" "arming the merge poll regressed"
  assert_contains "$out" "$case_dir/home/data/task-a/proof" \
    "the PR-ready step did not hand back where the proof lives"
  assert_contains "$out" "the invoice list stops showing duplicates" \
    "the PR-ready step did not hand back what the proof shows"
  pass "fm-pr-check: arming a merge poll hands the proof over with the PR link"
}


test_script_parses
test_help_renders_the_header
test_demonstrable_without_a_bundle_refuses_with_a_complete_remedy
test_demonstrable_with_a_bundle_passes
test_an_empty_file_is_not_evidence
test_non_demonstrable_passes_without_artifacts_or_noise
test_silence_is_not_an_attestation
test_an_unreadable_declaration_fails_closed
test_waiver_is_recorded_reasoned_and_still_announced
test_waiver_is_refused_on_an_attested_task
test_show_reports_a_declared_but_uncaptured_task
test_unknown_inputs_are_refused
test_spawn_records_the_declaration_into_the_task_record
test_spawn_records_an_attestation_and_records_nothing_when_none_was_declared
test_pr_check_hands_the_proof_over_with_the_link
