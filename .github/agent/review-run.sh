#!/usr/bin/env bash
# agent-review, step 1: run Codex on the checked-out PR head. No write token is
# present in this step; Codex runs in its read-only sandbox.
#
# Env: PR, CODEX_AUTH_JSON (ChatGPT-managed auth.json), GH_TOKEN (read-only
#      GITHUB_TOKEN, used only to fetch context) + lib.sh requirements.
# Outputs: ok=true|false

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

base=$(cfg .base_branch)
export CODEX_HOME="$RUNNER_TEMP/codex-home"
ctx="$RUNNER_TEMP/review-context"
mkdir -p "$CODEX_HOME" "$ctx"
chmod 700 "$CODEX_HOME"

cat >"$CODEX_HOME/config.toml" <<EOF
cli_auth_credentials_store = "file"
model = "$(cfg .review.model)"
model_reasoning_effort = "$(cfg .review.effort)"
EOF

if [[ -z "${CODEX_AUTH_JSON:-}" ]]; then
  echo "::error::CODEX_AUTH_JSON secret is not set."
  echo "ok=false" >>"$GITHUB_OUTPUT"; exit 0
fi
(umask 077 && printf '%s' "$CODEX_AUTH_JSON" >"$CODEX_HOME/auth.json")
sha256sum "$CODEX_HOME/auth.json" | cut -d' ' -f1 >"$RUNNER_TEMP/auth.sha256"

# Context Codex can read but could not fetch itself (its sandbox has no network).
pr_json=$(gh pr view "$PR" -R "$REPO" --json title,body,headRefName)
issue=$(issue_from_branch "$(jq -r .headRefName <<<"$pr_json")")
jq -r '"# PR #'"$PR"': " + .title + "\n\n" + .body' <<<"$pr_json" >"$ctx/pr.md"
gh issue view "$issue" -R "$REPO" --comments >"$ctx/issue.md"
git fetch -q --no-tags origin "+refs/heads/$base:refs/remotes/origin/$base"

sed -e "s#{{PR}}#$PR#g" -e "s#{{ISSUE}}#$issue#g" -e "s#{{BASE}}#$base#g" \
    -e "s#{{CTX}}#$ctx#g" -e "s#{{REPO}}#$REPO#g" -e "s#{{OWNER}}#${REPO%%/*}#g" \
    "$AGENT_DIR/review-prompt.md" >"$ctx/prompt.md"
notes=$(cfg '.review.notes // empty')
[[ -n "$notes" ]] && printf '\n## Repository-specific notes\n\n%s\n' "$notes" >>"$ctx/prompt.md"

set +e
env -u GH_TOKEN -u GITHUB_TOKEN -u CODEX_AUTH_JSON \
  codex exec --sandbox read-only --ephemeral --color never \
    --output-schema "$AGENT_DIR/review-schema.json" \
    -o "$RUNNER_TEMP/review.json" - <"$ctx/prompt.md"
rc=$?
set -e

if [[ $rc -eq 0 ]] && jq -e '.verdict' "$RUNNER_TEMP/review.json" >/dev/null 2>&1; then
  echo "ok=true" >>"$GITHUB_OUTPUT"
else
  echo "::error::codex exec failed (exit $rc) or returned no verdict."
  echo "ok=false" >>"$GITHUB_OUTPUT"
fi
