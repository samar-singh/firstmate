#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#
# CI-skip neutralization matrix (a marker that is harmless on a feature branch
# means "do not deploy" once a squash merge carries it onto the default branch):
#   (i) marker in the squash SUBJECT is neutralized via --subject
#   (j) marker in the squash BODY is neutralized via --body
#   (k) a clean message merges byte-identically to the pre-change invocation
#   (l) Co-authored-by / Refs #NNN trailers survive a realistic squash body
#   (m) a marker that cannot be removed refuses and says why
#   (n) an unreadable merge message refuses rather than merging blind
#   (o) --merge and --rebase refuse rather than pretending to fix
#   (p) near-miss text is not matched, so clean merges stay untouched
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # Every case gets a clean merge-message fixture by default, so the pre-existing
  # interface tests below exercise the ordinary path where nothing is neutralized.
  set_merge_message "$case_dir" 'feat: add a thing (#9)' '* feat: add a thing'
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# set_merge_message <case_dir> <headline> <body> [commit-message ...]: write the
# fixture the gh mock replays for fm-pr-merge.sh's merge-message read. The shape
# is the script's parse contract, verified against the real GitHub GraphQL API:
# line 1 is the headline's line count, line 2 is 1 when every branch commit was
# seen, line 3 is the PR state, then the headline, the body, and any commit
# messages. FM_TEST_PR_STATE overrides the state for the already-merged case.
set_merge_message() {
  local case_dir=$1 headline=$2 body=$3
  shift 3
  {
    printf '%s\n' "$(printf '%s\n' "$headline" | wc -l | tr -d ' ')"
    printf '1\n'
    printf '%s\n' "${FM_TEST_PR_STATE:-OPEN}"
    printf '%s\n' "$headline"
    printf '%s\n' "$body"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$case_dir/merge-message.fixture"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup and replaying the merge-message
# fixture for the CI-skip scan. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# Record --subject/--body values verbatim: they are multi-line, so the flat
# "$*" log above cannot carry them faithfully.
prev=
for arg in "$@"; do
  case "$prev" in
    --subject) printf '%s' "$arg" > "$FM_TEST_SUBJECT_OUT" ;;
    --body) printf '%s' "$arg" > "$FM_TEST_BODY_OUT" ;;
  esac
  prev=$arg
done
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "api graphql" ]; then
  if [ -n "\${FM_TEST_MERGE_MESSAGE_FAILS:-}" ]; then
    echo 'error: could not resolve to a PullRequest' >&2
    exit 1
  fi
  # Record what was actually asked for, so the tests can assert the wire
  # contract rather than trusting that the fixture was requested at all.
  printf '%s\n' "\$*" > "$case_dir/graphql-args"
  if [ -n "\${FM_TEST_MERGE_MESSAGE_RAW:-}" ]; then
    printf '%s' "\$FM_TEST_MERGE_MESSAGE_RAW"
    exit 0
  fi
  cat "$case_dir/merge-message.fixture"
  exit 0
fi
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "api graphql" ]; then
  cat "$case_dir/merge-message.fixture"
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_SUBJECT_OUT="$case_dir/subject.out" \
  FM_TEST_BODY_OUT="$case_dir/body.out" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# --- CI-skip neutralization -------------------------------------------------
#
# GitHub honours [skip ci], [ci skip], [no ci], [skip actions], [actions skip]
# and the skip-checks trailer anywhere in a commit message, subject or body. On
# a feature branch that is a legitimate optimisation; on the default branch it
# means "do not deploy", and nothing reports it.

# Build a case whose merge message is <headline>/<body>, run the merge, and
# leave stdout/stderr plus the recorded subject/body for the caller to assert.
# Args: name headline body [-- extra fm-pr-merge args...]. Echoes the case dir.
neutralize_case() {
  local name=$1 headline=$2 body=$3 case_dir
  shift 3
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"
  set_merge_message "$case_dir" "$headline" "$body"
  printf '%s\n' "$case_dir"
}

test_marker_in_subject_is_neutralized() {
  local case_dir subject
  case_dir=$(neutralize_case marker-subject \
    'chore(ci): retire the Actions responder [skip ci] (#31)' \
    '* chore(ci): retire the Actions responder')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "marker-subject: fm-pr-merge should merge with a neutralized subject"

  assert_present "$case_dir/subject.out" \
    "marker-subject: a poisoned subject must be replaced via --subject"
  subject=$(cat "$case_dir/subject.out")
  assert_not_contains "$subject" '[skip ci]' \
    "marker-subject: the merged subject still carries the CI-skip marker"
  assert_contains "$subject" '(#31)' \
    "marker-subject: GitHub's PR reference must survive neutralization"
  assert_contains "$subject" 'retire the Actions responder' \
    "marker-subject: the subject's own wording must survive neutralization"
  assert_absent "$case_dir/body.out" \
    "marker-subject: a clean body must be left to GitHub rather than rewritten"
  pass "fm-pr-merge neutralizes a CI-skip marker carried by the PR title"
}

test_marker_in_branch_commit_body_is_neutralized() {
  local case_dir body
  case_dir=$(neutralize_case marker-body \
    'docs(agents): record the shared bound (#250)' \
    '* docs(agents): record the shared openpyxl bound and the .env CWD trap [skip ci]')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/250 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "marker-body: fm-pr-merge should merge with a neutralized body"

  assert_present "$case_dir/body.out" \
    "marker-body: a poisoned body must be replaced via --body"
  body=$(cat "$case_dir/body.out")
  assert_not_contains "$body" '[skip ci]' \
    "marker-body: the merged body still carries the CI-skip marker"
  assert_contains "$body" 'record the shared openpyxl bound' \
    "marker-body: the body's own wording must survive neutralization"
  assert_absent "$case_dir/subject.out" \
    "marker-body: a clean subject must be left to GitHub rather than rewritten"
  pass "fm-pr-merge neutralizes a CI-skip marker carried by a branch commit body"
}

test_clean_message_merges_byte_identically() {
  local case_dir
  case_dir=$(neutralize_case clean-message \
    'feat(bin): preflight remote runtime tool paths (#1623)' \
    '* feat(bin): widen the remote runtime PATH')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/1623 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "clean-message: fm-pr-merge failed on a clean merge message"

  grep -qxF 'pr merge 1623 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "clean-message: a clean merge must invoke gh-axi exactly as before this change"
  assert_absent "$case_dir/subject.out" \
    "clean-message: a clean merge must not pass --subject"
  assert_absent "$case_dir/body.out" \
    "clean-message: a clean merge must not pass --body"
  pass "fm-pr-merge leaves a clean merge byte-identical to the pre-change invocation"
}

test_near_miss_text_is_not_treated_as_a_marker() {
  local case_dir
  # None of these is a string GitHub honours: the bracketed forms are exact, and
  # the trailer is only the skip-checks key. Matching them would rewrite merges
  # that were never at risk.
  case_dir=$(neutralize_case near-miss \
    'fix(ci): document [skip-ci] and [skip  ci] near-misses (#77)' \
    '* fix(ci): note that request-checks: true is not a skip trailer
* fix(ci): mention skipping ci in prose')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/77 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "near-miss: fm-pr-merge failed on a message with no real marker"

  grep -qxF 'pr merge 77 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "near-miss: near-miss text must not change the gh-axi invocation"
  assert_absent "$case_dir/subject.out" \
    "near-miss: near-miss text must not trigger a subject rewrite"
  assert_absent "$case_dir/body.out" \
    "near-miss: near-miss text must not trigger a body rewrite"
  pass "fm-pr-merge does not treat near-miss text as a CI-skip marker"
}

test_trailers_and_refs_survive_neutralization() {
  local case_dir body
  case_dir=$(neutralize_case trailers-survive \
    'fix(extraction): stream the sheet read (#412)' \
    '* fix(extraction): stream the sheet read

Reading the whole workbook held every row in memory, so a large upload
restarted the worker before extraction finished.

Refs #398
Co-authored-by: Ada Lovelace <ada@example.invalid>

* test(extraction): cover the streaming reader [skip ci]

Refs #412
Co-authored-by: Grace Hopper <grace@example.invalid>')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/412 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "trailers-survive: fm-pr-merge should merge with a neutralized body"

  body=$(cat "$case_dir/body.out")
  assert_not_contains "$body" '[skip ci]' \
    "trailers-survive: the merged body still carries the CI-skip marker"
  assert_contains "$body" 'Co-authored-by: Ada Lovelace <ada@example.invalid>' \
    "trailers-survive: a Co-authored-by trailer was lost"
  assert_contains "$body" 'Co-authored-by: Grace Hopper <grace@example.invalid>' \
    "trailers-survive: the trailer beside the marker was lost"
  assert_contains "$body" 'Refs #398' \
    "trailers-survive: a Refs #NNN line was lost"
  assert_contains "$body" 'Refs #412' \
    "trailers-survive: the Refs #NNN line beside the marker was lost"
  assert_contains "$body" 'restarted the worker before extraction finished.' \
    "trailers-survive: the commit body prose was lost"
  assert_contains "$body" '* test(extraction): cover the streaming reader' \
    "trailers-survive: the marker's own commit subject was lost with it"
  pass "fm-pr-merge preserves trailers, Refs lines and body structure while neutralizing"
}

test_skip_checks_trailer_is_removed() {
  local case_dir body
  case_dir=$(neutralize_case skip-checks-trailer \
    'chore(deps): bump the runtime pin (#88)' \
    '* chore(deps): bump the runtime pin

Refs #87

skip-checks: true')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/88 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "skip-checks-trailer: fm-pr-merge should merge with a neutralized body"

  body=$(cat "$case_dir/body.out")
  assert_not_contains "$body" 'skip-checks' \
    "skip-checks-trailer: the skip-checks trailer survived into the merged body"
  assert_contains "$body" 'Refs #87' \
    "skip-checks-trailer: an unrelated trailer was removed with the skip trailer"
  pass "fm-pr-merge removes a skip-checks trailer without touching other trailers"
}

test_unremovable_marker_refuses() {
  local case_dir rc
  # Neutralizing this subject would empty it, and gh silently drops an empty
  # --subject and lets GitHub's own marker-carrying default land instead. That
  # is the one failure that would fail silently in the dangerous direction.
  case_dir=$(neutralize_case unremovable-marker \
    'skip-checks: true' \
    '')

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/91 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unremovable-marker: fm-pr-merge should refuse"
  assert_grep 'CI-skip marker' "$case_dir/stderr" \
    "unremovable-marker: the refusal did not name the CI-skip marker"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unremovable-marker: gh-axi pr merge was invoked with a message known to be poisoned"
  pass "fm-pr-merge refuses when a detected marker cannot be safely removed"
}

test_unreadable_merge_message_refuses() {
  local case_dir rc
  case_dir=$(neutralize_case unreadable-message \
    'feat: something (#5)' \
    '* feat: something')

  set +e
  FM_TEST_MERGE_MESSAGE_FAILS=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/5 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable-message: fm-pr-merge should refuse rather than merge blind"
  assert_grep 'could not be read' "$case_dir/stderr" \
    "unreadable-message: the refusal did not explain that the merge message was unreadable"
  assert_grep 'CI-skip marker cannot be ruled out' "$case_dir/stderr" \
    "unreadable-message: the refusal did not tie itself to the CI-skip check"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unreadable-message: gh-axi pr merge was invoked without checking the merge message"
  pass "fm-pr-merge refuses when the message that would land cannot be read"
}

test_rebase_with_marker_refuses() {
  local case_dir rc
  # Rebase replays branch commits verbatim, so there is no merge message to
  # rewrite: GitHub returns an empty headline and body for this method.
  case_dir=$(make_case rebase-marker)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  : > "$case_dir/gh-axi.log"
  set_merge_message "$case_dir" '' '' 'chore(ci): drop the stale marker [skip ci]'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 -- --rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "rebase-marker: fm-pr-merge should refuse a rebase it cannot make safe"
  assert_grep 'CI-skip marker' "$case_dir/stderr" \
    "rebase-marker: the refusal did not name the CI-skip marker"
  assert_grep 'squash' "$case_dir/stderr" \
    "rebase-marker: the refusal did not point at the merge method that can be made safe"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "rebase-marker: gh-axi pr merge was invoked for a rebase carrying a marker"
  pass "fm-pr-merge refuses a rebase whose replayed commits carry a CI-skip marker"
}

test_every_honoured_marker_is_neutralized() {
  local case_dir subject marker inner n=0
  # GitHub honours five bracketed strings and two trailer spellings. Covering
  # only the commonest one would let any of the others be dropped silently.
  for marker in '[skip ci]' '[ci skip]' '[no ci]' '[skip actions]' '[actions skip]' '[SKIP CI]' '[Ci Skip]'; do
    n=$((n + 1))
    case_dir=$(neutralize_case "marker-sweep-$n" \
      "chore(ci): retire the responder $marker (#31)" \
      '* chore(ci): retire the responder')

    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "marker-sweep: fm-pr-merge should merge with '$marker' neutralized"

    assert_present "$case_dir/subject.out" \
      "marker-sweep: '$marker' was not detected in the merge subject"
    subject=$(cat "$case_dir/subject.out")
    assert_not_contains "$subject" "$marker" \
      "marker-sweep: '$marker' survived into the merged subject"
    # Swapping the delimiters rather than deleting the marker is what keeps the
    # sentence meaning what it did; deletion would leave a hole.
    inner=${marker#[}
    inner=${inner%]}
    assert_contains "$subject" "($inner)" \
      "marker-sweep: '$marker' was deleted rather than having its delimiters swapped"
  done
  pass "fm-pr-merge neutralizes every bracketed CI-skip marker GitHub honours, in any case"
}

test_both_skip_checks_trailer_spellings_are_removed() {
  local case_dir body spelling n=0
  for spelling in 'skip-checks: true' 'skip-checks:true' 'Skip-Checks: TRUE'; do
    n=$((n + 1))
    case_dir=$(neutralize_case "trailer-sweep-$n" \
      'chore(deps): bump the runtime pin (#88)' \
      "* chore(deps): bump the runtime pin

Refs #87

$spelling")

    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/88 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "trailer-sweep: fm-pr-merge should merge with '$spelling' removed"

    assert_present "$case_dir/body.out" \
      "trailer-sweep: '$spelling' was not detected"
    body=$(cat "$case_dir/body.out")
    assert_not_contains "$body" "$spelling" \
      "trailer-sweep: '$spelling' survived into the merged body"
    assert_contains "$body" 'Refs #87' \
      "trailer-sweep: an unrelated trailer was removed with '$spelling'"
  done
  pass "fm-pr-merge removes every skip-checks trailer spelling GitHub honours"
}

test_mid_body_skip_checks_trailer_is_left_alone() {
  local case_dir
  # A squash body concatenates branch commits, so a commit that legitimately
  # ended with this trailer lands its copy mid-body, where GitHub ignores it.
  # Rewriting over that would break a merge that was never at risk.
  case_dir=$(neutralize_case mid-body-trailer \
    'chore(deps): bump the runtime pin (#89)' \
    '* chore(deps): bump the runtime pin

skip-checks: true

* test(deps): cover the new pin

Refs #88')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/89 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "mid-body-trailer: fm-pr-merge failed on a message that was never at risk"

  grep -qxF 'pr merge 89 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "mid-body-trailer: a trailer GitHub does not honour changed the invocation"
  assert_absent "$case_dir/body.out" \
    "mid-body-trailer: a trailer GitHub does not honour triggered a body rewrite"
  pass "fm-pr-merge leaves a skip-checks trailer that is not the last line alone"
}

test_neutralization_is_reported() {
  local case_dir
  case_dir=$(neutralize_case reports-neutralization \
    'chore(ci): retire the responder [skip ci] (#31)' \
    '* chore(ci): retire the responder')

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "reports-neutralization: fm-pr-merge should merge"

  assert_grep 'CI-skip marker' "$case_dir/stderr" \
    "reports-neutralization: rewriting a merge message was not reported at all"
  pass "fm-pr-merge reports that it rewrote the merge message"
}

test_merge_message_is_requested_for_the_selected_method() {
  local case_dir args
  # The scan is only worth anything if it asked GitHub about the merge method
  # that will actually run, and asked for the branch commits when they land.
  case_dir=$(neutralize_case wire-contract-squash 'feat: a thing (#70)' '* feat: a thing')
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "wire-contract: squash merge failed"
  args=$(cat "$case_dir/graphql-args")
  assert_contains "$args" 'method=SQUASH' \
    "wire-contract: the squash path did not ask GitHub about a squash"
  assert_contains "$args" 'viewerMergeHeadlineText' \
    "wire-contract: the composed subject was never requested"
  assert_contains "$args" 'viewerMergeBodyText' \
    "wire-contract: the composed body was never requested"
  assert_not_contains "$args" 'commits.nodes' \
    "wire-contract: squash asked for branch commits that never land individually"

  case_dir=$(make_case wire-contract-rebase)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5050505050505050505050505050505050505050
  : > "$case_dir/gh-axi.log"
  set_merge_message "$case_dir" '' '' 'chore(ci): tidy the workflow'
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 -- --rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "wire-contract: rebase merge failed"
  args=$(cat "$case_dir/graphql-args")
  assert_contains "$args" 'method=REBASE' \
    "wire-contract: the rebase path did not ask GitHub about a rebase"
  assert_contains "$args" 'commits.nodes' \
    "wire-contract: rebase did not ask for the branch commits it replays onto the default branch"
  pass "fm-pr-merge asks GitHub about the merge method that will actually run"
}

test_two_token_method_flag_is_honoured() {
  local case_dir rc
  # `--method rebase` is ordinary gh syntax; misreading it would skip the whole
  # check while still performing the merge.
  case_dir=$(make_case two-token-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6060606060606060606060606060606060606060
  : > "$case_dir/gh-axi.log"
  set_merge_message "$case_dir" '' '' 'chore(ci): drop the stale marker [skip ci]'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 -- --method rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "two-token-method: --method rebase must be read as a rebase and refused"
  assert_grep 'CI-skip marker' "$case_dir/stderr" \
    "two-token-method: the refusal did not name the CI-skip marker"
  pass "fm-pr-merge reads the two-token --method form when choosing what to scan"
}

test_unknown_merge_method_refuses() {
  local case_dir rc
  case_dir=$(neutralize_case unknown-method 'feat: a thing [skip ci] (#73)' '* feat: a thing')

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 -- --method= \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unknown-method: an unreadable merge method must not skip the check"
  assert_grep 'merge method could not be determined' "$case_dir/stderr" \
    "unknown-method: the refusal did not name the unresolvable merge method"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unknown-method: gh-axi was invoked without ever checking the merge message"
  pass "fm-pr-merge refuses a merge method it cannot resolve rather than skipping the check"
}

test_garbled_merge_message_reply_refuses() {
  local case_dir rc
  # gh can exit 0 and still return nothing useful. Treating that as "clean" is
  # the same silent-dangerous direction the whole check exists to prevent.
  case_dir=$(neutralize_case garbled-reply 'feat: a thing (#74)' '* feat: a thing')

  set +e
  FM_TEST_MERGE_MESSAGE_RAW=$'1\n1\n' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "garbled-reply: a reply with no PR state must refuse"
  assert_grep 'could not be parsed' "$case_dir/stderr" \
    "garbled-reply: the refusal did not explain that the reply was unusable"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "garbled-reply: gh-axi was invoked on an unparseable merge message"
  pass "fm-pr-merge refuses a merge-message reply it cannot parse"
}

test_truncated_commit_list_refuses_for_rebase() {
  local case_dir rc
  # commits(first:100) can truncate. An unread commit could carry a marker, and
  # a rebase replays every one of them onto the default branch.
  case_dir=$(neutralize_case truncated-commits 'x' 'y')

  set +e
  FM_TEST_MERGE_MESSAGE_RAW=$'1\n0\nOPEN\n\n\nchore(ci): tidy the workflow\n' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/75 -- --rebase \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truncated-commits: an incompletely read commit list must refuse"
  assert_grep 'not every commit' "$case_dir/stderr" \
    "truncated-commits: the refusal did not explain the incomplete read"
  pass "fm-pr-merge refuses a rebase whose commit list it could not read in full"
}

test_multi_line_subject_refuses() {
  local case_dir rc
  case_dir=$(neutralize_case multi-line-subject 'x' 'y')

  set +e
  FM_TEST_MERGE_MESSAGE_RAW=$'2\n1\nOPEN\nfeat: a thing [skip ci] (#76)\nsecond subject line\n* feat: a thing\n' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/76 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "multi-line-subject: a multi-line subject must refuse rather than be truncated"
  assert_grep 'not a single line' "$case_dir/stderr" \
    "multi-line-subject: the refusal did not explain the multi-line subject"
  assert_absent "$case_dir/subject.out" \
    "multi-line-subject: a truncated subject was handed to gh-axi"
  pass "fm-pr-merge refuses a multi-line merge subject rather than silently truncating it"
}

test_body_emptied_by_neutralization_refuses() {
  local case_dir rc
  # Passing an empty --body blanks GitHub's composed body outright, so this
  # must refuse rather than destroy the message.
  case_dir=$(neutralize_case emptied-body 'chore(deps): bump the pin (#78)' 'skip-checks: true')

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/78 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "emptied-body: emptying the body must refuse"
  assert_grep 'empty' "$case_dir/stderr" \
    "emptied-body: the refusal did not explain that the body would be emptied"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "emptied-body: gh-axi was invoked with a body that would be blanked"
  pass "fm-pr-merge refuses rather than blanking a merge body it cannot clean"
}

test_caller_supplied_message_is_not_rewritten() {
  local case_dir rc
  case_dir=$(neutralize_case caller-message \
    'feat: a thing [skip ci] (#79)' '* feat: a thing')

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/79 -- --squash --body 'my own body' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "caller-message: firstmate must not rewrite a message its caller wrote"
  assert_absent "$case_dir/subject.out" \
    "caller-message: a subject was added alongside the caller's own message"
  pass "fm-pr-merge refuses rather than competing with a merge message its caller supplied"
}

test_marker_in_caller_args_refuses() {
  local case_dir rc
  case_dir=$(neutralize_case caller-arg-marker 'feat: a thing (#80)' '* feat: a thing')

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/80 -- --squash --subject 'feat: a thing [skip ci]' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "caller-arg-marker: a marker in the caller's own subject must refuse"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "caller-arg-marker: gh-axi was invoked with a caller subject carrying a marker"
  pass "fm-pr-merge refuses a CI-skip marker supplied in the caller's own merge arguments"
}

test_marker_in_caller_body_file_refuses() {
  local case_dir rc
  # gh-axi resolves --body-file by reading it, so the flattened argument list
  # alone would only ever see the path.
  case_dir=$(neutralize_case caller-body-file 'feat: a thing (#81)' '* feat: a thing')
  printf 'Deploy already handled by the release job. [skip ci]\n' > "$case_dir/notes.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/81 -- --squash --body-file "$case_dir/notes.md" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "caller-body-file: a marker inside --body-file must refuse"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "caller-body-file: gh-axi was invoked with a body file carrying a marker"
  pass "fm-pr-merge reads a caller's --body-file rather than only seeing its path"
}

test_already_merged_pr_is_not_refused() {
  local case_dir
  # A recovery re-run must keep gh-axi's idempotent success. Nothing can be
  # poisoned once the PR has landed, so an old marker must not strand the task.
  case_dir=$(make_case already-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4040404040404040404040404040404040404040
  : > "$case_dir/gh-axi.log"
  FM_TEST_PR_STATE=MERGED set_merge_message "$case_dir" \
    'chore(ci): retire the responder [skip ci] (#33)' \
    '* chore(ci): retire the responder [skip ci]'

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "already-merged: fm-pr-merge must not refuse a PR that already landed"

  grep -qxF 'pr merge 33 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "already-merged: gh-axi must still be reached so its idempotent success stands"
  pass "fm-pr-merge does not refuse an already-merged PR over a marker that already landed"
}

test_clean_rebase_still_merges() {
  local case_dir
  case_dir=$(make_case rebase-clean)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  : > "$case_dir/gh-axi.log"
  set_merge_message "$case_dir" '' '' 'chore(ci): tidy the workflow'

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 -- --rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "rebase-clean: a clean rebase must still merge"

  grep -qxF 'pr merge 65 --repo example/repo --rebase' "$case_dir/gh-axi.log" \
    || fail "rebase-clean: a clean rebase must invoke gh-axi exactly as before this change"
  pass "fm-pr-merge leaves a clean rebase untouched"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_marker_in_subject_is_neutralized
test_marker_in_branch_commit_body_is_neutralized
test_clean_message_merges_byte_identically
test_near_miss_text_is_not_treated_as_a_marker
test_trailers_and_refs_survive_neutralization
test_skip_checks_trailer_is_removed
test_unremovable_marker_refuses
test_unreadable_merge_message_refuses
test_rebase_with_marker_refuses
test_every_honoured_marker_is_neutralized
test_both_skip_checks_trailer_spellings_are_removed
test_mid_body_skip_checks_trailer_is_left_alone
test_neutralization_is_reported
test_merge_message_is_requested_for_the_selected_method
test_two_token_method_flag_is_honoured
test_unknown_merge_method_refuses
test_garbled_merge_message_reply_refuses
test_truncated_commit_list_refuses_for_rebase
test_multi_line_subject_refuses
test_body_emptied_by_neutralization_refuses
test_caller_supplied_message_is_not_rewritten
test_marker_in_caller_args_refuses
test_marker_in_caller_body_file_refuses
test_already_merged_pr_is_not_refused
test_clean_rebase_still_merges
