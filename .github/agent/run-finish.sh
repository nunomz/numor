#!/usr/bin/env bash
# agent-run, after Claude: the only place that writes to GitHub on Claude's
# behalf. Claude itself runs with a read-only token and never pushes.
#
# Env: ISSUE, PR (may be empty), MODE, BRANCH, START_SHA, CLAUDE_CONCLUSION,
#      STRUCTURED (Claude's JSON result), GH_TOKEN (GitHub App token)
#      + lib.sh requirements.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

base=$(cfg .base_branch)
out() { [[ -n "${STRUCTURED:-}" ]] && jq -r "$1 // empty" <<<"$STRUCTURED" 2>/dev/null || true; }

outcome=$(out .outcome)
summary=$(out .summary)
if [[ "${CLAUDE_CONCLUSION:-}" != success || -z "$outcome" ]]; then
  outcome=error
fi

fail() { # message
  remove_labels "$ISSUE" agent:working
  add_labels "$ISSUE" agent:failed
  comment "$ISSUE" "🤖 **Agent stopped.** $1

[Run log]($(run_url)) · Re-apply the \`agent\` label to retry."
  notify "❌ Agent stopped on #$ISSUE: $1
$(issue_url "$ISSUE")"
  exit 0
}

case "$outcome" in
  needs_info)
    questions=$(jq -r '(.questions // [])[] | "1. " + .' <<<"$STRUCTURED")
    remove_labels "$ISSUE" agent:working
    add_labels "$ISSUE" agent:needs-info
    comment "$ISSUE" "🤖 **I need some input before I continue.**

$summary

$questions

_Reply in a comment on this issue and I'll pick it back up automatically._"
    notify "❓ Claude has questions on #$ISSUE:

$questions

Answer here: $(issue_url "$ISSUE")"
    exit 0
    ;;
  blocked)
    fail "Claude reported it is blocked:

$summary"
    ;;
  error)
    fail "The Claude run failed or returned no result (conclusion: ${CLAUDE_CONCLUSION:-unknown})."
    ;;
  done) ;;
  *)
    fail "Unknown outcome '$outcome'."
    ;;
esac

# --- outcome: done -----------------------------------------------------------

current=$(git rev-parse --abbrev-ref HEAD)
[[ "$current" == "$BRANCH" ]] || fail "Claude left the repository on branch '$current' instead of '$BRANCH'."

# Commit anything Claude left uncommitted.
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "chore(agent): uncommitted changes from agent run" -m "Refs #$ISSUE"
fi

if [[ "$(git rev-parse HEAD)" == "$START_SHA" ]]; then
  fail "Claude reported done but produced no commits.

$summary"
fi
if [[ -z "$PR" ]] && git diff --quiet "origin/$base" HEAD; then
  fail "Claude's commits leave the branch identical to $base.

$summary"
fi

remote="https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
if [[ -n "$PR" ]]; then
  git push -q "$remote" "HEAD:refs/heads/$BRANCH" \
    || fail "Pushing to $BRANCH failed (Claude may have rewritten history, or touched .github/workflows, which the agent app cannot push)."
else
  # A fresh branch replaces any leftover branch of the same name without an open PR.
  git push -q --force "$remote" "HEAD:refs/heads/$BRANCH" \
    || fail "Pushing $BRANCH failed (the agent app cannot push changes to .github/workflows)."
fi

verification=$(out .verification)
remove_labels "$ISSUE" agent:working

if [[ -z "$PR" ]]; then
  title=$(out .pr_title)
  [[ -n "$title" ]] || title="Fix #$ISSUE"
  body="$summary

### Verification
${verification:-_Not reported._}

Closes #$ISSUE

---
🤖 Opened by the agent pipeline: Claude implements, Codex reviews, \`agent-gate\` merges when CI and review pass and the change is inside the auto-merge scope. Comment \`@claude …\` to request changes, \`/review\` to re-run Codex, or add \`agent:hold\` to stop auto-merge."
  PR=$(gh pr create -R "$REPO" --base "$base" --head "$BRANCH" --title "$title" --body "$body" | sed -n 's#.*/pull/\([0-9]*\)$#\1#p')
  notify "📬 PR #$PR opened for #$ISSUE: $title
$(pr_url "$PR")"
else
  remove_labels "$PR" agent:needs-human
  comment "$PR" "🤖 **Pushed an update** ($MODE).

$summary

### Verification
${verification:-_Not reported._}"
  notify "🔁 Claude pushed an update to PR #$PR
$(pr_url "$PR")"
fi
