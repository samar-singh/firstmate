#!/usr/bin/env bash
# fm-timeout-lib.sh - the ONE owner of firstmate's bounded external-command idiom.
#
# Any call into a tool firstmate does not control (a vendor CLI, a backend
# binary, a capability probe) can block forever, and several of those calls sit
# on paths that hold a lock. `fm_run_timed <seconds> <command...>` runs the
# command under a hard deadline and returns 124 when the deadline elapsed.
#
# The selection chain is load-bearing, not decoration: stock macOS ships neither
# timeout(1) nor gtimeout(1), so the perl SIGALRM fallback is what gives a
# developer Mac the same bound a Linux CI runner gets. The fallback runs the
# command in its own process group and escalates TERM then KILL to that group,
# so a hung child cannot outlive the bound by parking in a grandchild.
#
# A host with none of the three cannot be bounded at all; that returns 124
# without running the command, because an unbounded run is exactly what callers
# use this for avoiding. Callers must therefore treat 124 as "no answer", never
# as "the command said no".
#
# A non-positive bound is not a bound: `timeout 0` and the fallback's `alarm 0`
# both disable the deadline. Callers sanitize their own configured seconds
# before calling; see bin/fm-vendor-auth-probe.sh for the canonical pattern.

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 124
  fi
}
