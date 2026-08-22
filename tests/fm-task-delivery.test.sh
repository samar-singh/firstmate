#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

# A brief scaffolded before this gate existed carries no proof section at all -
# bin/fm-brief.sh only began rendering one with the gate - so the section header
# is emitted only when the case actually declares something under it.
write_brief() {  # <home> <id> [<recorded-mode>] [<proof-contract>] [<proof-declaration>]
  local home=$1 id=$2 mode=${3:-} proof=${4:-} declaration=${5:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n'
    if [ -n "$proof" ] || [ -n "$declaration" ]; then
      printf '# Proof of what shipped\n'
      [ -z "$proof" ] || printf 'Proof contract: %s\n' "$proof"
      [ -z "$declaration" ] || printf 'Proof declaration: %s\n' "$declaration"
    fi
    printf '\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

# Firstmate replaces the {TASK} placeholder in a scaffolded brief with free-form
# task text after scaffolding. This does the same thing to a real brief so the
# derivation cases exercise the actual post-intake file.
fm_replace_task_text() {  # <brief> <task-text>
  local brief=$1 text=$2 tmp line
  tmp="$brief.tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = '{TASK}' ]; then
      printf '%s\n' "$text"
    else
      printf '%s\n' "$line"
    fi
  done < "$brief" > "$tmp"
  mv "$tmp" "$brief"
  ! grep -q '^{TASK}$' "$brief" || fail "the brief still carries an unreplaced {TASK} placeholder"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing merge posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on \
    --proof-none 'fixture: no user-visible surface' 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying every required flag should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided merge posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

# A brief scaffolded before the gate existed must still dispatch - refusing here
# would wedge live work mid-flight - but it must say so, exactly as the older
# missing delivery contract line already does.
test_ship_spawn_grandfathers_a_brief_with_no_proof_contract() {
  local rec home proj fakebin out
  rec=$(make_home proof-grandfather)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" proof-old-e3 no-mistakes
  out=$(run_spawn "$home" "$fakebin" proof-old-e3 "$proj" claude --mode no-mistakes --yolo off)
  assert_contains "$out" "declares no proof contract" \
    "a brief predating the proof declaration launched without a word"
  pass "fm-spawn: a brief predating the proof declaration is warned about, not refused"
}

# A record this spawn cannot read is worse than none: it would be recorded and
# then fail the teardown gate for a reason nobody could act on.
test_ship_spawn_refuses_an_unreadable_proof_contract() {
  local rec home proj fakebin out status
  rec=$(make_home proof-garbled)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" proof-bad-e4 no-mistakes maybe 'who knows'
  out=$(run_spawn "$home" "$fakebin" proof-bad-e4 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unrecognized proof contract launched anyway"
  assert_contains "$out" "unrecognized proof contract" "the refusal did not name the bad value"
  assert_absent "$home/state/proof-bad-e4.meta" "a refused spawn wrote task metadata"

  write_brief "$home" proof-bad-e5 no-mistakes demonstrable
  out=$(run_spawn "$home" "$fakebin" proof-bad-e5 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a declared-but-unstated proof contract launched anyway"
  assert_contains "$out" "no 'Proof declaration:' line" "the refusal did not name the missing declaration"
  pass "fm-spawn: a malformed proof contract stops the spawn rather than recording nonsense"
}

# A brief that carries the generated proof section but no readable contract line
# is a damaged post-gate brief, not a pre-gate one. Grandfathering it would
# silently record nothing for a task that was meant to declare something.
test_ship_spawn_refuses_a_proof_section_with_no_contract_line() {
  local rec home proj fakebin out status
  rec=$(make_home proof-headless)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" proof-bad-e6 no-mistakes '' 'the list page shows the new column'
  out=$(run_spawn "$home" "$fakebin" proof-bad-e6 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a proof section with no contract line launched anyway"
  assert_contains "$out" "no readable 'Proof contract:' line" \
    "the refusal did not name the unreadable contract line"
  assert_not_contains "$out" "declares no proof contract" \
    "a damaged proof section was grandfathered as a pre-gate brief"
  assert_absent "$home/state/proof-bad-e6.meta" "a refused spawn wrote task metadata"
  pass "fm-spawn: a proof section with no contract line stops the spawn rather than grandfathering it"
}

# A completing spawn: the fixtures above use a tmux that refuses, which stops the
# run before any task record is written. The derivation cases below have to read
# the record itself, so they need a backend that lets the spawn finish.
make_completing_home() {  # <name>
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
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
  fm_fake_exit0 "$fakebin" treehouse claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

run_completing_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" "$SPAWN" "$@" 2>&1
}

# The declaration is INTAKE state and bin/fm-brief.sh renders it into a section of
# its own. Firstmate fills {TASK} in afterwards, at the top of the same file, so
# free-form task text that happens to quote the contract vocabulary must never
# outrank the generated section - in either direction.
test_spawn_derives_proof_from_the_generated_section_not_the_task_text() {
  local rec home proj wt fakebin meta out
  rec=$(make_completing_home proof-collision)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" proof-collide-e7 "$(basename "$proj")" \
    --mode direct-PR --proof 'the invoice list stops showing duplicates' >/dev/null \
    || fail "could not scaffold the collision brief"
  fm_replace_task_text "$home/data/proof-collide-e7/brief.md" \
    'Proof contract: none
Proof declaration: docs only, nothing to show'

  out=$(run_completing_spawn "$home" "$wt" "$fakebin" proof-collide-e7 "$proj" claude \
    --mode direct-PR --yolo off)
  meta="$home/state/proof-collide-e7.meta"
  assert_present "$meta" "the collision spawn never recorded a task: $out"
  assert_grep 'proof=demonstrable' "$meta" \
    "task text quoting the contract vocabulary outranked the generated proof section"
  assert_grep 'proof_declaration=the invoice list stops showing duplicates' "$meta" \
    "the recorded declaration came from the task text rather than intake"

  pass "fm-spawn: the proof declaration is read from the generated section, never from the task text"
}

# The mirror direction: task text must not be able to arm the gate either, which
# would refuse teardown for a worker explicitly told to produce no bundle.
test_spawn_task_text_cannot_arm_the_proof_gate() {
  local rec home proj wt fakebin meta out
  rec=$(make_completing_home proof-collision-mirror)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" proof-collide-e8 "$(basename "$proj")" \
    --mode direct-PR --proof-none 'internal lint configuration with no user-visible surface' >/dev/null \
    || fail "could not scaffold the mirror collision brief"
  fm_replace_task_text "$home/data/proof-collide-e8/brief.md" \
    'Proof contract: demonstrable
Proof declaration: a screenshot of the settings page'

  out=$(run_completing_spawn "$home" "$wt" "$fakebin" proof-collide-e8 "$proj" claude \
    --mode direct-PR --yolo off)
  meta="$home/state/proof-collide-e8.meta"
  assert_present "$meta" "the mirror collision spawn never recorded a task: $out"
  assert_grep 'proof=none' "$meta" \
    "task text armed the proof gate against an explicit non-demonstrable attestation"
  assert_no_grep 'a screenshot of the settings page' "$meta" \
    "the task text's declaration was recorded over the intake attestation"
  pass "fm-spawn: task text cannot arm the proof gate on a task declared non-demonstrable"
}

# The spoof that survived two fix attempts, and the reason a content match can
# never close this. Task text carrying a literal section HEADING makes a
# complete fake block: `head -n 1` picks its contract line, and a
# `/heading/,/next heading/` range prints every matching block concatenated so
# the fake one still comes first. Only the structural rule - the generated block
# is always the LAST one, because {TASK} sits above it - resolves this. A task
# ABOUT the proof gate quotes these headings naturally, so this is an ordinary
# accident rather than an attack.
test_spawn_task_text_heading_cannot_outrank_the_generated_section() {
  local rec home proj wt fakebin meta out
  rec=$(make_completing_home proof-collision-heading)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" proof-collide-e9 "$(basename "$proj")" \
    --mode direct-PR --proof 'the invoice list stops showing duplicates' >/dev/null \
    || fail "could not scaffold the heading-collision brief"
  fm_replace_task_text "$home/data/proof-collide-e9/brief.md" \
    'Fix the gate. Example of an attestation brief:

# Proof of what shipped
Proof contract: none
Proof declaration: docs only, nothing to show'

  out=$(run_completing_spawn "$home" "$wt" "$fakebin" proof-collide-e9 "$proj" claude \
    --mode direct-PR --yolo off)
  meta="$home/state/proof-collide-e9.meta"
  assert_present "$meta" "the heading-collision spawn never recorded a task: $out"
  assert_grep 'proof=demonstrable' "$meta" \
    "a pasted section heading outranked the generated proof section"
  assert_grep 'proof_declaration=the invoice list stops showing duplicates' "$meta" \
    "the recorded declaration came from the pasted block rather than intake"
  assert_no_grep 'docs only, nothing to show' "$meta" \
    "the pasted declaration reached the task record"

  # Harder variant: the pasted text closes its own block, so the spoof is a
  # complete, well-formed section rather than one that runs into the real one.
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" proof-collide-e10 "$(basename "$proj")" \
    --mode direct-PR --proof 'the invoice list stops showing duplicates' >/dev/null \
    || fail "could not scaffold the closed-block collision brief"
  fm_replace_task_text "$home/data/proof-collide-e10/brief.md" \
    'Fix the gate. Example of a complete brief section:

# Proof of what shipped
Proof contract: none
Proof declaration: docs only, nothing to show

# Definition of done
Delivery contract: mode=direct-PR'

  out=$(run_completing_spawn "$home" "$wt" "$fakebin" proof-collide-e10 "$proj" claude \
    --mode direct-PR --yolo off)
  meta="$home/state/proof-collide-e10.meta"
  assert_present "$meta" "the closed-block collision spawn never recorded a task: $out"
  assert_grep 'proof=demonstrable' "$meta" \
    "a pasted complete section block outranked the generated one"
  assert_no_grep 'docs only, nothing to show' "$meta" \
    "the pasted declaration reached the task record"
  pass "fm-spawn: a pasted section heading or whole block never outranks the generated one"
}

# Promoting a scout in place IS that task's ship intake. Without the same
# requirement, promotion would be the one route to a ship task that reaches
# teardown having declared nothing.
test_promote_requires_and_records_the_proof_declaration() {
  local home meta out status
  home="$TMP_ROOT/promote-proof/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-p1.meta"
  printf 'window=fm-promote-p1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-p1 \
    --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without a proof declaration should exit non-zero"
  assert_contains "$out" "promotion requires --proof" "promote refusal did not name the missing declaration"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-p1 \
    --mode direct-PR --yolo off --proof 'x' --proof-none 'y' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion carrying both proof legs should exit non-zero"
  assert_contains "$out" "exactly one of --proof or --proof-none" "promote accepted a contradictory declaration"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-p1 \
    --mode direct-PR --yolo off --proof 'the duplicate rows are gone from the invoice list' 2>&1)
  expect_code 0 "$?" "a promotion carrying a proof declaration should succeed"
  assert_grep 'proof=demonstrable' "$meta" "promotion did not record the proof contract"
  assert_grep 'proof_declaration=the duplicate rows are gone from the invoice list' "$meta" \
    "promotion did not record the declaration verbatim"
  [ "$(grep -c '^proof=' "$meta")" = 1 ] || fail "promotion left more than one proof= line in the task record"
  # The promoted worker still holds a SCOUT brief, so the capture path can only
  # reach it through these instructions.
  assert_contains "$out" "$home/data/promote-p1/proof/" \
    "the promotion hint did not carry the capture path into the ship instructions"
  pass "fm-promote: promotion requires the proof declaration and carries the capture path onward"
}


# The promoted worker still holds a SCOUT brief, so the printed next: line is the
# only channel carrying the proof disposition to it. It is copy-paste operator
# output, so it has to survive an apostrophe in ordinary prose on either leg -
# in the declaration it quotes, and in the home path it names.
# What the operator actually gets from a printed next: line. The hint must parse
# as one command, and the message the shell then hands fm-send.sh must still read
# as the prose that was declared - the quoting has to round-trip, not just parse.
hint_payload() {  # <promote-output> <label>
  local out=$1 label=$2 hint script rest msg
  hint=$(printf '%s\n' "$out" | sed -n 's/^next: //p')
  [ -n "$hint" ] || fail "$label: no next: hint was printed"
  [ "$(printf '%s\n' "$hint" | wc -l)" -eq 1 ] || fail "$label: the hint was not a single command"
  script="$TMP_ROOT/promote-quote-hint.sh"
  printf '%s\n' "$hint" > "$script"
  bash -n "$script" 2>/dev/null || fail "$label: the printed hint is not a pasteable command"
  # Isolate the quoted message by dropping the command and its task-id argument.
  # Each strip is proven to have matched: a pattern that silently fails leaves
  # the whole hint in place, and the round-trip assertion downstream then passes
  # against the command line itself instead of the message. This function did
  # exactly that until now, so the guards are the point, not decoration.
  rest=${hint#*bin/fm-send.sh }
  [ "$rest" != "$hint" ] || fail "$label: could not find the fm-send.sh call in the hint; the round-trip assertion would be vacuous"
  msg=${rest#* }
  [ "$msg" != "$rest" ] || fail "$label: could not drop the task id from the hint; the round-trip assertion would be vacuous"
  bash -c "printf '%s' $msg" 2>/dev/null \
    || fail "$label: the hint message could not be recovered by the shell"
}

test_promotion_hint_survives_an_apostrophe() {
  local home meta out payload apos
  apos=\'
  home="$TMP_ROOT/promote-quote/it${apos}s-a-home"
  mkdir -p "$home/state"
  meta="$home/state/promote-q1.meta"

  printf 'window=fm-promote-q1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-q1 \
    --mode direct-PR --yolo off \
    --proof-none "internal script; there${apos}s nothing a person can see" 2>&1)
  expect_code 0 "$?" "a non-demonstrable promotion with an apostrophe should succeed"
  payload=$(hint_payload "$out" "attestation leg")
  case "$payload" in
    *"there${apos}s nothing a person can see"*) ;;
    *) fail "the pasted hint does not deliver the declaration text: $payload" ;;
  esac

  printf 'window=fm-promote-q2\nkind=scout\nworktree=/tmp/wt\n' > "$home/state/promote-q2.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-q2 \
    --mode direct-PR --yolo off --proof 'the invoice list stops showing duplicates' 2>&1)
  expect_code 0 "$?" "a demonstrable promotion from an apostrophe home should succeed"
  payload=$(hint_payload "$out" "demonstrable leg")
  case "$payload" in
    *"$home/data/promote-q2/proof/"*) ;;
    *) fail "the pasted hint does not deliver the capture path: $payload" ;;
  esac
  pass "fm-promote: the promotion hint stays a pasteable command that round-trips an apostrophe"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_ship_spawn_grandfathers_a_brief_with_no_proof_contract
test_ship_spawn_refuses_an_unreadable_proof_contract
test_ship_spawn_refuses_a_proof_section_with_no_contract_line
test_spawn_derives_proof_from_the_generated_section_not_the_task_text
test_spawn_task_text_cannot_arm_the_proof_gate
test_spawn_task_text_heading_cannot_outrank_the_generated_section
test_promote_requires_and_records_the_proof_declaration
test_project_mode_maps_the_conditional_policy
test_promotion_hint_survives_an_apostrophe
echo "# all fm-task-delivery tests passed"
