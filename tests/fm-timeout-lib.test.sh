#!/usr/bin/env bash
# tests/fm-timeout-lib.test.sh - unit tests for the bounded external-command
# helper (bin/fm-timeout-lib.sh), the single owner of `fm_run_timed`.
#
# Three consumers depend on this contract on the spawn and snapshot paths:
# bin/fm-spawn.sh's claude Remote Control capability probe, bin/fm-fleet-snapshot.sh's
# bounded reads, and bin/fm-vendor-auth-probe.sh's vendor CLI calls. Each treats
# 124 as "no answer" and each runs where a hang would hold a lock, so both halves
# of the contract are pinned here: a prompt command is passed through untouched,
# and a command that overruns is killed and reported as 124.
#
# Pure functions, no backend and no live spawn required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-timeout-lib)

# The bound and the overrun are kept far apart in both directions: long enough
# that a loaded machine cannot trip the deadline early, short enough that the
# elapsed-time assertions have room to spare.
BOUND=2
OVERRUN=30
MARGIN=20

# --- a prompt command is passed through untouched ---------------------------

out=$(fm_run_timed "$BOUND" sh -c 'printf ready') || fail "a prompt command must not fail"
[ "$out" = ready ] || fail "fm_run_timed must return the command's own stdout, got '$out'"
pass "a command that returns within the bound yields its own output"

rc=0
fm_run_timed "$BOUND" sh -c 'exit 7' || rc=$?
[ "$rc" -eq 7 ] || fail "fm_run_timed must return the command's own exit status, got $rc"
pass "a command that returns within the bound yields its own exit status"

rc=0
fm_run_timed "$BOUND" sh -c 'exit 0' || rc=$?
[ "$rc" -eq 0 ] || fail "a successful command must stay successful, got $rc"
pass "success is not disturbed by the bound"

# --- a command that overruns is terminated and reported as 124 --------------

started=$(date +%s)
rc=0
fm_run_timed "$BOUND" sleep "$OVERRUN" || rc=$?
elapsed=$(( $(date +%s) - started ))
[ "$rc" -eq 124 ] || fail "an overrunning command must yield 124, got $rc"
[ "$elapsed" -lt "$MARGIN" ] || fail "the bound did not fire: ${elapsed}s elapsed against a ${BOUND}s bound"
pass "a command that exceeds the bound is terminated and reported as 124"

# --- the bound still holds with no timeout(1) on PATH -----------------------
#
# Stock macOS ships neither timeout nor gtimeout, so the perl SIGALRM fallback
# is what bounds every developer Mac. Exercise it directly by giving the call a
# PATH that holds only the interpreters and the command under test.

MINBIN="$TMP_ROOT/minbin"
mkdir -p "$MINBIN"
for tool in sh sleep perl; do
  src=$(command -v "$tool") || fail "this test host has no $tool, which fm_run_timed's fallback needs"
  ln -s "$src" "$MINBIN/$tool"
done

if ( PATH="$MINBIN"; command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 ); then
  fail "the reduced PATH still resolves timeout or gtimeout, so the fallback is not the path under test"
fi

started=$(date +%s)
rc=0
( PATH="$MINBIN"; fm_run_timed "$BOUND" sleep "$OVERRUN" ) || rc=$?
elapsed=$(( $(date +%s) - started ))
[ "$rc" -eq 124 ] || fail "the perl fallback must yield 124 on overrun, got $rc"
[ "$elapsed" -lt "$MARGIN" ] || fail "the perl fallback did not bound the command: ${elapsed}s elapsed"
pass "the bound is enforced with no timeout(1) available, through the perl fallback"

out=$( PATH="$MINBIN"; fm_run_timed "$BOUND" sh -c 'printf ready' ) || fail "the perl fallback must not fail a prompt command"
[ "$out" = ready ] || fail "the perl fallback must return the command's own stdout, got '$out'"
rc=0
( PATH="$MINBIN"; fm_run_timed "$BOUND" sh -c 'exit 7' ) || rc=$?
[ "$rc" -eq 7 ] || fail "the perl fallback must return the command's own exit status, got $rc"
pass "the perl fallback passes a prompt command's output and status through unchanged"

echo "# all fm-timeout-lib tests passed"
