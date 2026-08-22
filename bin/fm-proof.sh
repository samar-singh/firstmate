#!/usr/bin/env bash
# fm-proof.sh - the ship-task proof-of-work contract: what would prove this
# change, and whether that proof survived.
#
# WHY THIS EXISTS. A scout was already guaranteed a surviving artifact: its
# report is the deliverable, and bin/fm-teardown.sh refuses to erase a scout
# that has none. A ship task - the one that changes what the captain's users
# see - was guaranteed nothing. Its definition of done ended at a commit, a
# green pipeline, and a merged PR, so the screenshots, transcripts, and logs a
# run produced were routinely written into a temp directory and cleaned away,
# taking the PR's own evidence links with them. That asymmetry is what this
# script closes.
#
# WHAT THIS IS NOT. This is not a second verification pass, and nothing here
# asks anyone to check the work again. The selected delivery path still owns
# every bit of rigor (AGENTS.md section 7), and no-mistakes already emits this
# evidence with nobody asking. The only requirement added is DURABILITY: the
# evidence that already exists must land somewhere that outlives the worktree,
# and the captain must be handed it with the PR instead of having to ask.
#
# Usage:
#   fm-proof.sh verify <task-id>
#   fm-proof.sh show <task-id>
#   fm-proof.sh waive <task-id> --reason <why no proof survives>
#
# THE DECLARATION IS MADE AT INTAKE, BY FIRSTMATE, AND NOT BY THIS SCRIPT.
# Asked at the end, "what would prove this?" only ever produces a rationale for
# whatever happened to occur. Asked at intake it is an acceptance criterion and
# doubles as a specification check, so the declaration is written where intake
# happens and this script only reads it:
#
#   bin/fm-brief.sh   --proof <what would prove this> | --proof-none <why not>
#                     REQUIRED on every ship scaffold. Renders the worker's
#                     capture contract and the fixed machine-readable
#                     "Proof contract: <demonstrable|none>" line.
#   bin/fm-spawn.sh   derives proof= and proof_declaration= for a fresh ship
#                     spawn from that brief line, so the record cannot disagree
#                     with the worker's own instructions.
#   bin/fm-promote.sh --proof | --proof-none, REQUIRED, because promoting a
#                     scout in place is that task's ship intake.
#
# There is deliberately no re-declare command. The intake declaration is
# immutable through this script's surface; `waive` below is the only late act,
# and it is loud.
#
# THE RECORD (state/<task-id>.meta), mirroring how decisions_reviewed= and
# decision_keys= record the scout completion gate in the same file:
#
#   proof=demonstrable   something would show this change working
#   proof=none           an explicit attestation that nothing would; the direct
#                        analog of bin/fm-captain-hold.sh's `complete --none`
#   proof=waived         a late, recorded admission that the declared proof did
#                        not survive (see `waive`)
#   proof_declaration=<one line>   what would prove it, why it would not, or why
#                        the waiver was needed - required by every value above
#   (no proof= key)      NOBODY DECLARED ANYTHING. This is not an attestation and
#                        never reads as one; see `verify`.
#
# THE BUNDLE is data/<task-id>/proof/ - beside the scout's report.md, in the
# durable per-task data directory that outlives teardown. Any layout is fine;
# a short notes.md saying what each file shows and which claim it supports is
# what makes the bundle reviewable, but this gate never requires a filename.
#
# `verify` is read-only and is what bin/fm-teardown.sh calls before erasing a
# ship task. Four outcomes, three of which pass:
#
#   proof=demonstrable  PASS only when the bundle holds at least one non-empty
#                       file. Otherwise REFUSE, naming the declaration, the
#                       bundle path, and every way to satisfy it.
#   proof=none          PASS silently. A refactor, a dependency bump, a docs
#                       fix, or an internal script is genuinely not
#                       demonstrable, and demanding artifacts for those is
#                       worse than useless: it trains every reader to skim the
#                       evidence, and then the real proof gets skimmed too. The
#                       escape hatch is a first-class path, not a bypass flag.
#   proof=waived        PASS with a loud warning naming the recorded reason.
#   no proof= key       PASS with a warning. A task spawned before this gate
#                       existed has no declaration and must not wedge; the same
#                       one-release grandfathering bin/fm-spawn.sh already
#                       applies to a brief that records no delivery contract
#                       line. The warning is what keeps silence distinguishable
#                       from proof=none, which passes without a word.
#
# An unrecognized proof= value refuses: a record this script cannot read is not
# evidence that the captain's proof exists.
#
# `show` prints the one-line handover bin/fm-pr-check.sh emits beside the armed
# merge poll, so the proof reaches the captain WITH the PR link rather than
# after the captain asks for it.
#
# `waive` records, in the task's own metadata, that the declared proof did not
# survive and why. It exists so a mid-flight scope change has an honest answer
# that is not `fm-teardown.sh --force`, which also skips the landed-work checks
# and is reserved for explicitly authorized discard. A waiver is durable,
# greppable, and warned about on every later verify.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

PROOF_META_LOCK=
PROOF_META_LOCK_HELD=0
proof_cleanup() {
  if [ "$PROOF_META_LOCK_HELD" = 1 ]; then
    PROOF_META_LOCK_HELD=0
    fm_lock_release "$PROOF_META_LOCK" || true
  fi
}
trap proof_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-proof: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty privacy-safe slug: $2" ;;
  esac
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# The bundle is proven present by at least one non-empty regular file anywhere
# under it. -size +0c is bytes; bare -size +0 counts BSD blocks and would pass
# an empty placeholder on macOS.
bundle_files() {  # <dir>
  [ -d "$1" ] || { printf '0\n'; return 0; }
  find "$1" -type f -size +0c 2>/dev/null | wc -l | tr -d ' '
}

file_count_phrase() {  # <count>
  if [ "$1" -eq 1 ]; then
    printf '1 file\n'
  else
    printf '%s files\n' "$1"
  fi
}

resolve_task() {  # <task-id>
  validate_slug task-id "$1"
  ID=$1
  META="$STATE/$ID.meta"
  BUNDLE="$DATA/$ID/proof"
  [ -f "$META" ] || fail "no task metadata at $META"
  PROOF=$(meta_value "$META" proof)
  DECLARATION=$(meta_value "$META" proof_declaration)
}

command_verify() {
  local count
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  resolve_task "$1"
  case "$PROOF" in
    '')
      printf 'fm-proof: warning: ship task %s carries no proof declaration (spawned before the proof gate, or from a brief with no proof contract line); nothing is being enforced for it\n' "$ID" >&2
      printf 'unenforced: %s has no proof declaration on record\n' "$ID"
      ;;
    none)
      printf 'verified: %s declared not demonstrable (%s)\n' "$ID" "$DECLARATION"
      ;;
    waived)
      printf 'fm-proof: warning: the declared proof for %s did not survive and was waived: %s\n' "$ID" "$DECLARATION" >&2
      printf 'verified: %s proof waived\n' "$ID"
      ;;
    demonstrable)
      count=$(bundle_files "$BUNDLE")
      if [ "$count" -eq 0 ]; then
        printf 'fm-proof: %s declared at intake that this would prove it: %s\n' "$ID" "$DECLARATION" >&2
        printf 'fm-proof: no such proof survives - %s holds no non-empty file.\n' "$BUNDLE" >&2
        printf 'fm-proof: satisfy it one of three ways:\n' >&2
        printf 'fm-proof:   1. copy the evidence the run already produced into %s (screenshots, before/after transcripts, command output, logs). It is capture, not a new verification pass.\n' "$BUNDLE" >&2
        printf 'fm-proof:   2. if the shipped change turned out not to be demonstrable, record that honestly: bin/fm-proof.sh waive %s --reason "<why no proof survives>"\n' "$ID" >&2
        printf 'fm-proof:   3. only with explicit captain authority to discard the work, bin/fm-teardown.sh --force\n' >&2
        exit 1
      fi
      printf 'verified: %s proof bundle at %s (%s)\n' "$ID" "$BUNDLE" "$(file_count_phrase "$count")"
      ;;
    *)
      fail "task $ID records an unrecognized proof declaration '$PROOF'; repair state/$ID.meta before teardown"
      ;;
  esac
}

command_show() {
  local count
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  resolve_task "$1"
  case "$PROOF" in
    '') printf 'proof: undeclared for %s - no intake declaration on record\n' "$ID" ;;
    none) printf 'proof: none for %s - %s\n' "$ID" "$DECLARATION" ;;
    waived) printf 'proof: waived for %s - %s\n' "$ID" "$DECLARATION" ;;
    demonstrable)
      count=$(bundle_files "$BUNDLE")
      if [ "$count" -eq 0 ]; then
        printf 'proof: declared for %s but not yet captured - %s (expected in %s)\n' "$ID" "$DECLARATION" "$BUNDLE"
      else
        printf 'proof: %s (%s) - %s\n' "$BUNDLE" "$(file_count_phrase "$count")" "$DECLARATION"
      fi
      ;;
    *) fail "task $ID records an unrecognized proof declaration '$PROOF'" ;;
  esac
}

command_waive() {
  local id='' reason='' want=''
  while [ "$#" -gt 0 ]; do
    if [ -n "$want" ]; then
      case "$1" in --*) fail "--$want requires a value" ;; esac
      reason=$1
      want=
      shift
      continue
    fi
    case "$1" in
      --reason) want=reason ;;
      --reason=*) reason=${1#--reason=} ;;
      --*) fail "unknown flag $1" ;;
      *) [ -z "$id" ] || fail "waive takes exactly one task id"; id=$1 ;;
    esac
    shift
  done
  [ -z "$want" ] || fail "--$want requires a value"
  [ -n "$id" ] || { usage >&2; exit 2; }
  [ -n "$reason" ] || fail "waive requires --reason: record why the declared proof did not survive"
  case "$reason" in
    *$'\n'*|*$'\r'*) fail "--reason must be one line" ;;
  esac
  resolve_task "$id"
  [ "$PROOF" != none ] \
    || fail "task $ID already attested that it is not demonstrable; a waiver would only obscure that"
  PROOF_META_LOCK=$(fm_meta_lock_path "$META") || fail "could not resolve the task metadata lock"
  fm_lock_acquire_wait "$PROOF_META_LOCK"
  PROOF_META_LOCK_HELD=1
  [ -f "$META" ] || fail "task metadata disappeared while recording the waiver"
  printf 'proof=waived\nproof_declaration=%s\n' "$reason" >> "$META"
  fm_lock_release "$PROOF_META_LOCK"
  PROOF_META_LOCK_HELD=0
  printf 'waived: %s proof - %s\n' "$ID" "$reason"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  verify) shift; command_verify "$@" ;;
  show) shift; command_show "$@" ;;
  waive) shift; command_waive "$@" ;;
  *) usage >&2; exit 2 ;;
esac
