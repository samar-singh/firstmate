#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Before merging, the message GitHub would write onto the default branch is read
# back from GitHub itself and checked for the CI-skip markers Actions honours. A
# marker is a legitimate optimisation on a feature branch and means "do not
# deploy" once it lands on the default branch, where nothing reports it. Both
# entry paths are covered because both are inside that one message: the PR title
# becomes the squash subject, and the branch commit messages become the squash
# body. When the message is clean this script invokes gh-axi exactly as it did
# before that check existed, so nothing changes for a merge that was never at
# risk. bin/fm-merge-message-lib.sh owns the marker set and the neutralizer, and
# docs/verification/merge-message-ci-skip.md records the dated evidence.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-message-lib.sh
. "$SCRIPT_DIR/fm-merge-message-lib.sh"

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

# The merge method GitHub will actually use, as a GraphQL PullRequestMergeMethod.
# Fails when the caller named a method this script does not recognise, because
# scanning the wrong method's message would check text that never lands.
effective_merge_method() {
  local arg prev=
  for arg in "$@"; do
    if [ "$prev" = --method ]; then
      case "$arg" in
        squash) echo SQUASH ; return 0 ;;
        merge) echo MERGE ; return 0 ;;
        rebase) echo REBASE ; return 0 ;;
        *) return 1 ;;
      esac
    fi
    case "$arg" in
      --squash|--method=squash) echo SQUASH ; return 0 ;;
      --merge|--method=merge) echo MERGE ; return 0 ;;
      --rebase|--method=rebase) echo REBASE ; return 0 ;;
      --method|--method=*) return 1 ;;
    esac
    prev=$arg
  done
  echo SQUASH
}

# Whether the caller supplied its own merge message. Such a message is the
# caller's to own, so this script refuses rather than rewriting or competing
# with it: gh-axi rejects two body sources and silently keeps only the first
# --subject.
caller_sets_merge_message() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --subject|--subject=*|-t|--body|--body=*|-b|--body-file|--body-file=*|-F)
        return 0
        ;;
    esac
  done
  return 1
}

# Every byte of caller-supplied text that could reach the merge message. A
# --body-file is resolved and read by gh-axi, so the flattened argument list
# alone would only ever see its path.
caller_message_text() {
  local arg text path prev=''
  text=$*
  for arg in "$@"; do
    path=
    case "$prev" in
      --body-file|-F) path=$arg ;;
    esac
    case "$arg" in
      --body-file=*) path=${arg#--body-file=} ;;
      -F?*) path=${arg#-F} ;;
    esac
    if [ -n "$path" ] && [ -f "$path" ]; then
      text=$text$'\n'$(cat "$path")
    fi
    prev=$arg
  done
  printf '%s' "$text"
}

refuse_merge() {
  echo "error: refusing to merge: $1" >&2
  exit 1
}

# Ask GitHub for the exact message it will write rather than reproducing its
# composition. The repository's squash-message settings are applied server-side
# and are absent from the API for a non-admin reader, so reading GitHub's own
# composed text is the only way to know what actually lands.
#
# The reply is a plain text block: line 1 is the subject's line count, line 2 is
# 1 when every branch commit was seen, line 3 is the PR state, then the subject,
# then the body, then (for merge and rebase, whose branch commits land on the
# default branch individually) every branch commit message.
# shellcheck disable=SC2016  # $owner/$repo/$number/$method are GraphQL variables, not shell ones.
FM_MERGE_MSG_QUERY='query FmMergeMessage($owner:String!,$repo:String!,$number:Int!,$method:PullRequestMergeMethod!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state viewerMergeHeadlineText(mergeType:$method) viewerMergeBodyText(mergeType:$method) commits(first:100){pageInfo{hasNextPage}nodes{commit{message}}}}}}'
FM_MERGE_MSG_JQ='.data.repository.pullRequest | (.viewerMergeHeadlineText|split("\n")|length), (if .commits.pageInfo.hasNextPage then 0 else 1 end), .state, .viewerMergeHeadlineText, .viewerMergeBodyText'
FM_MERGE_MSG_JQ_COMMITS=', (.commits.nodes[].commit.message)'

read_merge_message() {
  local method=$1 jq_expr=$FM_MERGE_MSG_JQ
  [ "$method" = SQUASH ] || jq_expr="$jq_expr$FM_MERGE_MSG_JQ_COMMITS"
  gh api graphql \
    -f query="$FM_MERGE_MSG_QUERY" \
    -f owner="$PR_OWNER" -f repo="$PR_REPO" -F number="$PR_NUMBER" \
    -f method="$method" --jq "$jq_expr"
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
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

# Refuse to carry a CI-skip marker onto the default branch. message_args stays
# empty unless a marker is actually found, so a clean merge invokes gh-axi with
# exactly the arguments it used before this check existed.
message_args=()
if ! MERGE_METHOD=$(effective_merge_method "$@"); then
  refuse_merge "the merge method could not be determined, so a CI-skip marker cannot be ruled out"
fi
if ! MERGE_MESSAGE=$(read_merge_message "$MERGE_METHOD"); then
  refuse_merge "the message this merge would write could not be read, so a CI-skip marker cannot be ruled out"
fi
headline_lines=$(printf '%s\n' "$MERGE_MESSAGE" | sed -n 1p)
commits_seen=$(printf '%s\n' "$MERGE_MESSAGE" | sed -n 2p)
pr_state=$(printf '%s\n' "$MERGE_MESSAGE" | sed -n 3p)
case "$headline_lines" in ''|*[!0-9]*) headline_lines=0 ;; esac
case "$pr_state" in OPEN|CLOSED|MERGED) ;; *) pr_state= ;; esac
if [ "$headline_lines" -lt 1 ] || [ -z "$pr_state" ] \
  || { [ "$commits_seen" != 0 ] && [ "$commits_seen" != 1 ]; }; then
  refuse_merge "the message this merge would write could not be parsed, so a CI-skip marker cannot be ruled out"
fi

# An already-merged PR has nothing left to poison, and gh-axi answers it with
# idempotent success. Recovery re-runs must keep that behaviour.
if [ "$pr_state" != MERGED ]; then
  if [ "$MERGE_METHOD" != SQUASH ] && [ "$commits_seen" != 1 ]; then
    refuse_merge "not every commit this $MERGE_METHOD merge would land could be read, so a CI-skip marker cannot be ruled out"
  fi
  if [ "$#" -gt 0 ] && fm_merge_msg_has_ci_skip "$(caller_message_text "$@")"; then
    refuse_merge "the supplied merge arguments carry a CI-skip marker; firstmate will not rewrite a message its caller wrote"
  fi

  scanned=$(printf '%s\n' "$MERGE_MESSAGE" | tail -n +4)
  if fm_merge_msg_has_ci_skip "$scanned"; then
    # Only a squash collapses the branch into the single message this script
    # can replace. A merge commit and a rebase both push the branch commits
    # themselves onto the default branch, and their messages are replayed
    # verbatim, so there is nothing here that can make them safe.
    if [ "$MERGE_METHOD" != SQUASH ]; then
      refuse_merge "a CI-skip marker would land on the default branch and a $MERGE_METHOD merge replays commit messages verbatim; merge with --squash, or amend the offending commit"
    fi
    if caller_sets_merge_message "$@"; then
      refuse_merge "a CI-skip marker would land on the default branch and the caller supplied its own merge message"
    fi
    if [ "$headline_lines" -ne 1 ]; then
      refuse_merge "the merge subject is not a single line, so a CI-skip marker cannot be removed from it safely"
    fi

    headline=$(printf '%s\n' "$MERGE_MESSAGE" | sed -n 4p)
    body=$(printf '%s\n' "$MERGE_MESSAGE" | tail -n +5)
    clean_headline=$(fm_merge_msg_neutralize "$headline")
    clean_body=$(fm_merge_msg_neutralize "$body")
    if fm_merge_msg_has_ci_skip "$clean_headline" || fm_merge_msg_has_ci_skip "$clean_body"; then
      refuse_merge "a CI-skip marker survived neutralization"
    fi
    # A replacement that begins with a dash can be re-read as a flag by the
    # layers below rather than used as the message, which would drop the
    # replacement and let GitHub's own marker-carrying default land while this
    # script reported success.
    case "$clean_headline" in
      -*) refuse_merge "the neutralized merge subject would start with a dash and could be mistaken for an option" ;;
    esac
    case "$clean_body" in
      -*) refuse_merge "the neutralized merge body would start with a dash and could be mistaken for an option" ;;
    esac
    if [ "$clean_headline" != "$headline" ]; then
      # gh drops an empty --subject silently and lets GitHub's own default -
      # still carrying the marker - land instead, so an emptied subject is the
      # one failure that would fail silently in the dangerous direction.
      if [ -z "$(printf '%s' "$clean_headline" | tr -d '[:space:]')" ]; then
        refuse_merge "removing the CI-skip marker would leave the merge subject empty"
      fi
      message_args+=(--subject "$clean_headline")
    fi
    if [ "$clean_body" != "$body" ]; then
      if [ -z "$clean_body" ]; then
        refuse_merge "removing the CI-skip marker would leave the merge message body empty"
      fi
      message_args+=(--body "$clean_body")
    fi
    echo "notice: removed a CI-skip marker from the message this merge writes to the default branch; without it the merge would have landed without running CI" >&2
  fi
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "${message_args[@]+"${message_args[@]}"}" "$@"
