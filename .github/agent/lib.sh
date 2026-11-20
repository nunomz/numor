#!/usr/bin/env bash
# Shared helpers for the agent pipeline (agent-*.yml). Sourced, not executed.
#
# Expects: GITHUB_REPOSITORY, and GH_TOKEN for gh calls. Telegram is optional:
# without TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID, notify() only logs.

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$AGENT_DIR/config.json"
REPO="${GITHUB_REPOSITORY:?}"
REPO_NAME="${REPO#*/}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

cfg() { jq -r "$1" "$CONFIG"; }

issue_url() { echo "$SERVER_URL/$REPO/issues/$1"; }
pr_url() { echo "$SERVER_URL/$REPO/pull/$1"; }
run_url() { echo "$SERVER_URL/$REPO/actions/runs/${GITHUB_RUN_ID:-0}"; }

# notify "text" — Telegram message prefixed with the repo name. Never fails the job.
notify() {
  local text="[$REPO_NAME] $1"
  echo "notify: $text"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "::warning::Telegram secrets not set; notification only logged."
    return 0
  fi
  # Telegram caps messages at 4096 characters.
  text="${text:0:4000}"
  curl -sS --fail-with-body --max-time 20 -o /dev/null \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true" \
    || echo "::warning::Telegram notification failed."
}

add_labels() { # number label...
  local n=$1; shift
  local args=()
  for l in "$@"; do args+=(--add-label "$l"); done
  gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null
}

remove_labels() { # number label... (ignores labels that are not present)
  local n=$1; shift
  local present
  present=$(gh issue view "$n" -R "$REPO" --json labels --jq '.labels[].name')
  for l in "$@"; do
    if grep -qxF "$l" <<<"$present"; then
      gh issue edit "$n" -R "$REPO" --remove-label "$l" >/dev/null
    fi
  done
}

has_label() { # number label
  gh issue view "$1" -R "$REPO" --json labels --jq '.labels[].name' | grep -qxF "$2"
}

comment() { # number body (issues and PRs share the comments API)
  gh issue comment "$1" -R "$REPO" --body "$2" >/dev/null
}

# Number of the open agent PR for a branch, or empty.
pr_for_branch() {
  gh pr list -R "$REPO" --head "$1" --state open --json number --jq '.[0].number // empty'
}

# The issue an agent branch belongs to: agent/issue-42 -> 42.
issue_from_branch() {
  sed -n 's#^agent/issue-\([0-9][0-9]*\)$#\1#p' <<<"$1"
}

dispatch_run() { # issue mode [pr] [reason]
  gh workflow run agent-run.yml -R "$REPO" --ref "$(cfg .base_branch)" \
    -f issue="$1" -f mode="$2" -f pr="${3:-}" -f reason="${4:-}"
}
