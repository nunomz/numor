#!/usr/bin/env bash
# agent-run, before Claude: check out the branch Claude works on.
# Env: ISSUE, PR (may be empty), MODE + lib.sh requirements.
# Outputs (GITHUB_OUTPUT): branch, pr

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

base=$(cfg .base_branch)

if [[ -n "${PR:-}" ]]; then
  branch=$(gh pr view "$PR" -R "$REPO" --json headRefName --jq .headRefName)
else
  branch="agent/issue-$ISSUE"
  PR=$(pr_for_branch "$branch")
fi

if [[ "$(issue_from_branch "$branch")" != "$ISSUE" ]]; then
  echo "::error::Branch $branch does not belong to issue #$ISSUE."; exit 1
fi

if [[ -n "$PR" ]]; then
  # Continue on the open PR's branch.
  git fetch --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  git checkout -B "$branch" "origin/$branch"
else
  # Fresh start from the base branch (a leftover branch without an open PR is replaced).
  git checkout -B "$branch" "origin/$base"
fi

git config user.name "${AGENT_GIT_NAME:-claude-agent}"
git config user.email "${AGENT_GIT_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

{
  echo "branch=$branch"
  echo "pr=$PR"
  echo "base_sha=$(git rev-parse HEAD)"
} >>"$GITHUB_OUTPUT"
echo "Working on $branch (PR: ${PR:-none})"
