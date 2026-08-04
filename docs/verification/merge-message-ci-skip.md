# Merge-message CI-skip verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the guarantee in `bin/fm-pr-merge.sh` that a merge firstmate performs never carries a CI-skip marker onto a default branch.
`bin/fm-merge-message-lib.sh` owns the marker set and the neutralizer.
Exact task chronology, branch names, and delivery transcripts remain in private reports or PR evidence.

The guarantee rests on GitHub behavior that is not stated in GitHub's REST or GraphQL public reference, so it is recorded here rather than assumed.
Re-run these commands after any GitHub change that touches merge-message composition.

## Markers GitHub honours

Read from GitHub's own documentation on 2026-08-04, at
<https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs>.

The complete honoured set is five bracketed strings plus a trailer in two spellings:

```text
[skip ci]  [ci skip]  [no ci]  [skip actions]  [actions skip]
skip-checks:true   skip-checks: true
```

The bracketed forms are documented without any position requirement: "you add any of the following strings to the commit message in a push, or the HEAD commit of a pull request".
Only the trailer carries one: "The trailers section should be included at the end of your commit message and be preceded by two empty lines."
Skip instructions apply to the `push` and `pull_request` events only, and no workflow can opt out of being skipped, which is why the fix belongs at the merge boundary rather than in any workflow file.

A skipped workflow leaves its required checks in a "Pending" state rather than resolving them, so a repository that requires those checks blocks the pull request from merging.

### A squash commit's body is scanned, not only its subject

The documentation does not state this directly, so it was established empirically on 2026-08-04.
Squash commit `268a44d3622d3258b75d235de80e990158ff6761` in `pyOpenSci/python-package-guide` (PR #776, single parent) has a clean subject and two `[skip ci]` lines in its body.
Its repository runs `build-book.yml` on `push: branches: [main]`.

Observed, for that commit and its three immediate neighbours on `main`:

```text
723250a933 | PUSH_RUNS=1 | marker_in_body=0
268a44d362 | PUSH_RUNS=0 | marker_in_body=2
35c6a2dd98 | PUSH_RUNS=1 | marker_in_body=0
48b6d36d7a | PUSH_RUNS=1 | marker_in_body=0
```

Stripping the body is therefore necessary, not defensive.

### Case sensitivity

GitHub's own matching appears to be case-sensitive.
In `linuxdeepin/dde-tray-loader`, 51 distinct push-event workflow runs have a head commit whose subject begins with `[skip CI]`, and zero have a lowercase `[skip ci]` head commit.

`bin/fm-merge-message-lib.sh` nevertheless matches case-insensitively.
The asymmetry decides it: over-matching costs two substituted characters on text GitHub would have ignored, while under-matching ships a half-deployed system.
Several non-Actions CI systems also honour these markers case-insensitively.

## GitHub composes the merge message server-side and will report it

`viewerMergeHeadlineText(mergeType:)` and `viewerMergeBodyText(mergeType:)` return the exact text GitHub will write, with the repository's squash-message settings already applied.
This matters because `squash_merge_commit_title` and `squash_merge_commit_message` are absent from the repositories API for a non-admin reader, so they cannot be read at merge time.

Verified on 2026-08-04 with gh 2.80.0 against `kunchenguid/firstmate` PR #1631, which had ten commits:

```sh
gh api graphql -f query='query($owner:String!,$repo:String!,$number:Int!,$method:PullRequestMergeMethod!){repository(owner:$owner,name:$repo){pullRequest(number:$number){viewerMergeHeadlineText(mergeType:$method) viewerMergeBodyText(mergeType:$method)}}}' \
  -f owner=kunchenguid -f repo=firstmate -F number=1631 -f method=SQUASH
```

Observed headline, carrying the ` (#N)` suffix GitHub generates itself:

```text
feat: strengthen supervision lifecycle controls (#1631)
```

Observed body, one `* `-prefixed subject per branch commit with each commit's full body flush-left:

```text
* fix: reconcile retained supervision state

* no-mistakes(review): Fix supervision state, progress, drain, and remote steering
...
```

The same query with `-f method=MERGE` returned the classic merge headline and the pull request title as the body, so a marker in a pull request title reaches a merge commit's message:

```text
HEADLINE: 'Merge pull request #1631 from coreldh/fm/c0803-o2-fold'
BODY: 'feat: strengthen supervision lifecycle controls'
```

The same query with `-f method=REBASE` returned the empty string for both fields:

```text
HEADLINE: ''
BODY: ''
```

That is GitHub stating there is no merge message for a rebase, because branch commits are replayed verbatim.
`bin/fm-pr-merge.sh` therefore detects and refuses on that path rather than pretending to fix it.

## The parse contract

`bin/fm-pr-merge.sh` reads the message as a plain text block rather than parsing JSON, so it needs no `jq` on the host.
Verified on 2026-08-04 with gh 2.80.0:

```sh
gh api graphql -f query='query FmMergeMessage($owner:String!,$repo:String!,$number:Int!,$method:PullRequestMergeMethod!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state viewerMergeHeadlineText(mergeType:$method) viewerMergeBodyText(mergeType:$method) commits(first:100){pageInfo{hasNextPage}nodes{commit{message}}}}}}' \
  -f owner=kunchenguid -f repo=firstmate -F number=1631 -f method=SQUASH \
  --jq '.data.repository.pullRequest | (.viewerMergeHeadlineText|split("\n")|length), (if .commits.pageInfo.hasNextPage then 0 else 1 end), .state, .viewerMergeHeadlineText, .viewerMergeBodyText'
```

Observed first lines:

```text
1
1
OPEN
feat: strengthen supervision lifecycle controls (#1631)
* fix: reconcile retained supervision state
```

The leading line count is what makes the split safe: the subject is taken only when GitHub reports it as a single line, so a multi-line headline refuses rather than silently spilling into the body.

## Supplying a message does not disturb the half left alone

Established from the cli/cli source at the installed version, gh 2.80.0.
`pkg/cmd/pr/merge/http.go` sets the GraphQL fields conditionally:

```go
if payload.commitSubject != "" {
	commitHeadline := githubv4.String(payload.commitSubject)
	input.CommitHeadline = &commitHeadline
}
if payload.setCommitBody {
	commitBody := githubv4.String(payload.commitBody)
	input.CommitBody = &commitBody
}
```

Two consequences the implementation depends on:

- The body is gated on flag presence, not on value, so passing only `--subject` leaves the body to GitHub rather than blanking it. `Co-authored-by` trailers on the untouched half therefore survive.
- The headline is gated on a non-empty value, so an empty `--subject` is silently dropped and GitHub's own default, still carrying the marker, lands instead. `bin/fm-pr-merge.sh` refuses rather than emitting an empty subject, because that is the one failure that would fail silently in the dangerous direction.

A supplied headline is used verbatim; GitHub does not append ` (#N)` to it.
gh's own interactive "Edit commit subject" flow prefills from `viewerMergeHeadlineText`, which already contains the suffix, and posts it straight back, so a server-side append would double it in gh itself.
The implementation does not depend on this being true: it substitutes two delimiter characters inside GitHub's own headline rather than constructing one, so the suffix is carried through rather than generated.

## Regression coverage

`tests/fm-pr-merge.test.sh` pins the behavior, including that a clean merge invokes `gh-axi` with exactly the arguments it used before this check existed.

```sh
bash tests/fm-pr-merge.test.sh
bin/fm-test-run.sh --family pr-forge
```
