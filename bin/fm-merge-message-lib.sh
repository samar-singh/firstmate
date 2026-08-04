#!/usr/bin/env bash
# Detect and neutralize the CI-skip markers GitHub Actions honours, in the one
# commit message a pull-request merge writes onto the default branch.
#
# GitHub honours five bracketed strings anywhere in a commit message, subject or
# body, plus a skip-checks trailer in two spellings:
#   [skip ci]  [ci skip]  [no ci]  [skip actions]  [actions skip]
#   skip-checks:true   skip-checks: true
# See https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs
# and docs/verification/merge-message-ci-skip.md for the dated evidence that a
# squash commit's BODY is scanned too, not only its subject.
#
# A bracketed marker is neutralized by swapping its delimiters, never by
# deleting it, so meaning and length survive:
#   "stop [skip ci] riding squash merges" -> "stop (skip ci) riding squash merges"
# Deletion would have produced "stop  riding squash merges" and inverted the
# sense. The swap can never synthesize a different marker, because every string
# GitHub honours requires the square brackets the swap removes.
#
# The trailer form carries no prose, only the directive, so its whole line goes.
# It is matched only at column 0 and only as the last non-blank line, because
# that is the only position GitHub honours it in: "The trailers section should be
# included at the end of your commit message". A squash body concatenates every
# branch commit, so a commit that legitimately ended with this trailer lands its
# copy in the middle of the composed body, where GitHub ignores it. Deleting that
# copy would rewrite a merge that was never at risk and lose a line of a commit
# message, so only the honoured position is treated as a marker.
#
# Matching is case-insensitive even though GitHub's own matching appears to be
# case-sensitive (docs/verification/merge-message-ci-skip.md records the
# evidence). The asymmetry decides it: over-matching costs two substituted
# characters on text GitHub would have ignored, while under-matching ships a
# half-deployed system. Several non-Actions CI systems also honour these markers
# case-insensitively, and firstmate merges for projects that use them.
#
# Detection is defined as "neutralizing changes the text", so detection and
# neutralization can never disagree about what counts as a marker.

# fm_merge_msg_neutralize <text>: print <text> with every CI-skip marker
# neutralized. Output is otherwise byte-for-byte the input, apart from a
# trailing newline. Fails if the text could not be processed, so a caller under
# "set -e" refuses rather than acting on a partial result.
fm_merge_msg_neutralize() {
  local swapped
  # Captured rather than piped straight through, so a sed that aborts partway -
  # BSD sed does that on a byte sequence invalid in the active locale - is a
  # failure rather than silently truncated output.
  swapped=$(printf '%s\n' "$1" | sed \
    -e 's/\[\([sS][kK][iI][pP] [cC][iI]\)\]/(\1)/g' \
    -e 's/\[\([cC][iI] [sS][kK][iI][pP]\)\]/(\1)/g' \
    -e 's/\[\([nN][oO] [cC][iI]\)\]/(\1)/g' \
    -e 's/\[\([sS][kK][iI][pP] [aA][cC][tT][iI][oO][nN][sS]\)\]/(\1)/g' \
    -e 's/\[\([aA][cC][tT][iI][oO][nN][sS] [sS][kK][iI][pP]\)\]/(\1)/g') || return 1
  printf '%s\n' "$swapped" | awk '
    { line[NR] = $0 }
    END {
      drop = 0
      for (i = NR; i >= 1; i--) {
        if (line[i] ~ /[^ \t]/) {
          # Only the two spellings GitHub documents, and only here at the end.
          if (tolower(line[i]) ~ /^skip-checks: ?true\r?$/) drop = i
          break
        }
      }
      for (i = 1; i <= NR; i++) if (i != drop) print line[i]
    }'
}

# fm_merge_msg_has_ci_skip <text>: succeed when <text> carries a marker GitHub
# would honour. Defined against the neutralizer so the two cannot drift. Both
# sides go through command substitution so that trailing newlines are stripped
# from each alike, and only a real difference counts as a marker.
fm_merge_msg_has_ci_skip() {
  [ "$(fm_merge_msg_neutralize "$1")" != "$(printf '%s' "$1")" ]
}
