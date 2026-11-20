#!/usr/bin/env bash
# agent-gate: decides what happens to an agent PR once its checks settle.
#
#   all checks green + Codex approved + inside auto-merge scope -> squash-merge
#   all green but outside scope / on hold                       -> ping the owner
#   something failed, fix rounds left                           -> dispatch a Claude fix round
#   something failed, no rounds left                            -> ping the owner
#
# Free private repos have no branch protection, so this script *is* the merge
# policy. Claude and Codex never hold a token that can merge.
#
# Env: BRANCH (agent/issue-N) or PR, HEAD_SHA (optional: the SHA that triggered
#      this run), GH_TOKEN (GitHub App token), READ_TOKEN (the job's GITHUB_TOKEN,
#      for check runs) + lib.sh requirements.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ -z "${PR:-}" ]]; then
  PR=$(pr_for_branch "$BRANCH")
  [[ -n "$PR" ]] || { echo "No open PR for $BRANCH."; exit 0; }
fi

# GitHub computes mergeability lazily; give it a moment after a push.
for _ in 1 2 3 4 5 6; do
  pr_json=$(gh pr view "$PR" -R "$REPO" --json number,title,headRefName,headRefOid,isDraft,labels,mergeable,additions,deletions,changedFiles,state,isCrossRepository)
  [[ "$(jq -r .mergeable <<<"$pr_json")" != UNKNOWN ]] && break
  sleep 5
done
[[ "$(jq -r .state <<<"$pr_json")" == OPEN ]] || { echo "PR #$PR is not open."; exit 0; }
# Agent PRs are always same-repo branches. A fork can name its branch agent/... too.
[[ "$(jq -r .isCrossRepository <<<"$pr_json")" == false ]] || { echo "PR #$PR comes from a fork; ignoring."; exit 0; }
sha=$(jq -r .headRefOid <<<"$pr_json")
branch=$(jq -r .headRefName <<<"$pr_json")
title=$(jq -r .title <<<"$pr_json")
issue=$(issue_from_branch "$branch")
[[ -n "$issue" ]] || { echo "PR #$PR is not an agent PR."; exit 0; }

if [[ -n "${HEAD_SHA:-}" && "$HEAD_SHA" != "$sha" ]]; then
  echo "Run was for $HEAD_SHA but the PR head is now $sha; a newer run will decide."; exit 0
fi

marker="<!-- agent-gate:$sha -->"
comments=$(gh api "repos/$REPO/issues/$PR/comments" --paginate --jq '.[].body')
if grep -qF "$marker" <<<"$comments"; then
  echo "Already decided for $sha."; exit 0
fi

# --- collect results for the head commit ---------------------------------------

# The App has no Checks permission; the job's read-only GITHUB_TOKEN does.
checks=$(GH_TOKEN="${READ_TOKEN:-$GH_TOKEN}" gh api "repos/$REPO/commits/$sha/check-runs?per_page=100" --paginate \
  --jq '.check_runs[] | select(.app.slug == "github-actions") | {name, status, conclusion, url: .html_url}' | jq -s .)
# The pipeline's own jobs are not results (the Codex verdict is a commit status).
checks=$(jq '[.[] | select(.name != "gate" and .name != "codex-review")]' <<<"$checks")

pending=$(jq -r '[.[] | select(.status != "completed")] | length' <<<"$checks")
if [[ "$pending" -gt 0 ]]; then
  echo "$pending check(s) still running; waiting."; exit 0
fi

missing=()
while IFS= read -r req; do
  [[ -z "$req" ]] && continue
  jq -e --arg n "$req" 'any(.[]; .name == $n)' <<<"$checks" >/dev/null || missing+=("$req")
done < <(cfg '.required_checks[]')
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Required check(s) not reported yet: ${missing[*]}; waiting."; exit 0
fi

failed=$(jq -r '.[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral") | "- ❌ [\(.name)](\(.url)): \(.conclusion)"' <<<"$checks")

review=$(gh api "repos/$REPO/commits/$sha/statuses" --jq '[.[] | select(.context == "agent/codex-review")][0] // empty')
review_state=""
[[ -n "$review" ]] && review_state=$(jq -r '.state // empty' <<<"$review")
case "$review_state" in
  "" | pending)
    echo "Codex review not finished for $sha; waiting."; exit 0 ;;
  error)
    comment "$PR" "$marker
🤖 **Codex review could not run** for $sha, so this PR will not auto-merge. Comment \`/review\` to retry, or review it yourself."
    add_labels "$PR" agent:needs-human
    notify "⚠️ Codex review failed to run on PR #$PR (auth expired?). Needs you:
$(pr_url "$PR")"
    exit 0 ;;
  failure)
    failed+=$'\n'"- ❌ Codex requested changes (see the review comment above)" ;;
esac

mergeable=$(jq -r .mergeable <<<"$pr_json")
if [[ "$mergeable" == CONFLICTING ]]; then
  failed+=$'\n'"- ❌ Merge conflict with \`$(cfg .base_branch)\`: merge the base branch into this branch and resolve the conflicts (no force-push, no rebase)"
fi
failed=$(sed '/^$/d' <<<"$failed")

# --- something failed: fix round or hand off -----------------------------------

if [[ -n "$failed" ]]; then
  max=$(cfg .max_auto_fix_rounds)
  rounds=$(grep -cF '<!-- agent-fix-round -->' <<<"$comments" || true)
  if [[ "$rounds" -lt "$max" ]]; then
    round=$((rounds + 1))
    comment "$PR" "$marker
<!-- agent-fix-round -->
🤖 **Auto-fix round $round/$max** for $sha:

$failed"
    add_labels "$issue" agent:working
    dispatch_run "$issue" fix "$PR" "Auto-fix round $round/$max. These failed on $sha:
$failed
Read the failing logs (gh run view <run-id> --log-failed) and the latest Codex review comment on the PR, then fix the causes."
    notify "🔁 PR #$PR failed checks, auto-fix round $round/$max:
$failed
$(pr_url "$PR")"
  else
    comment "$PR" "$marker
🤖 **Still failing after $max auto-fix rounds.** Over to you:

$failed

Comment \`@claude …\` with guidance to try again."
    add_labels "$PR" agent:needs-human
    notify "🙋 PR #$PR still failing after $max fix rounds. Needs you:
$failed
$(pr_url "$PR")"
  fi
  exit 0
fi

# --- all green: merge or hand off ----------------------------------------------

reasons=()
[[ "$(cfg .automerge.enabled)" == true ]] || reasons+=("auto-merge is disabled for this repo")
[[ "$(jq -r .isDraft <<<"$pr_json")" == false ]] || reasons+=("the PR is a draft")
if jq -e '.labels | any(.name == "agent:hold")' <<<"$pr_json" >/dev/null; then reasons+=("it has the agent:hold label"); fi
[[ "$mergeable" == MERGEABLE ]] || reasons+=("GitHub reports mergeable=$mergeable")

lines=$(jq -r '.additions + .deletions' <<<"$pr_json")
files=$(jq -r .changedFiles <<<"$pr_json")
[[ "$lines" -le "$(cfg .automerge.max_changed_lines)" ]] || reasons+=("$lines changed lines (limit $(cfg .automerge.max_changed_lines))")
[[ "$files" -le "$(cfg .automerge.max_changed_files)" ]] || reasons+=("$files changed files (limit $(cfg .automerge.max_changed_files))")

# (Explicit if/fi: a trailing failed `&&` would make the loop, and with
# `set -e` the whole script, exit non-zero when nothing matches.)
blocked=$(gh pr diff "$PR" -R "$REPO" --name-only | while IFS= read -r f; do
  while IFS= read -r re; do
    if [[ -n "$re" ]] && grep -qE -- "$re" <<<"$f"; then echo "$f"; break; fi
  done < <(cfg '.automerge.blocked_paths[]')
done)
[[ -z "$blocked" ]] || reasons+=("it touches protected paths: $(paste -sd, <<<"$blocked")")

if [[ ${#reasons[@]} -eq 0 ]]; then
  if gh pr merge "$PR" -R "$REPO" --squash --delete-branch --match-head-commit "$sha"; then
    comment "$PR" "$marker
🤖 **Auto-merged**: CI green, Codex approved, inside the auto-merge scope."
    notify "✅ Merged PR #$PR: $title (closes #$issue)
$(pr_url "$PR")"
    exit 0
  fi
  reasons+=("the merge call failed (see the gate log)")
fi

why=$(printf -- '- %s\n' "${reasons[@]}")
comment "$PR" "$marker
🤖 **Ready for your review.** CI is green and Codex approved, but I did not auto-merge because:

$why"
add_labels "$PR" agent:needs-human
notify "👀 PR #$PR ready for your merge: $title
Not auto-merged because:
$why
$(pr_url "$PR")"
