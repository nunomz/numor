#!/usr/bin/env bash
# agent-review, step 2: persist Codex's refreshed login, then publish the
# verdict as a PR comment plus the agent/codex-review commit status that
# agent-gate reads.
#
# Env: PR, SHA, OK (from step 1), GH_TOKEN (GitHub App token for this repo),
#      SYNC_TOKEN (App token for every repo it is installed on) + lib.sh requirements.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 1. Codex refreshes ChatGPT tokens in auth.json (refresh tokens rotate). All repos
#    the agent App is installed on share one CI login, so write the refreshed file
#    back to every one of them, or their next run starts from a dead token.
auth="$RUNNER_TEMP/codex-home/auth.json"
if [[ -s "$auth" && -s "$RUNNER_TEMP/auth.sha256" ]]; then
  if [[ "$(sha256sum "$auth" | cut -d' ' -f1)" != "$(cat "$RUNNER_TEMP/auth.sha256")" ]]; then
    for r in $(GH_TOKEN="$SYNC_TOKEN" gh api /installation/repositories --paginate --jq '.repositories[].full_name'); do
      GH_TOKEN="$SYNC_TOKEN" gh secret set CODEX_AUTH_JSON -R "$r" <"$auth" \
        && echo "Stored refreshed Codex auth in $r." \
        || echo "::warning::Could not store refreshed Codex auth in $r."
    done
  fi
fi

status() { # state description
  gh api -X POST "repos/$REPO/statuses/$SHA" -f state="$1" -f context=agent/codex-review \
    -f description="${2:0:140}" -f target_url="$(run_url)" >/dev/null
}

# 2. Publish.
if [[ "${OK:-false}" != true ]]; then
  status error "Codex review did not run"
  notify "⚠️ Codex review failed to run on PR #$PR. If this repeats, the Codex login secret needs re-seeding.
$(run_url)"
  exit 0
fi

r="$RUNNER_TEMP/review.json"
verdict=$(jq -r .verdict "$r")
findings=$(jq -r '.findings[] | "- **\(.severity)** `\(.file)\(if .line then ":\(.line)" else "" end)` \(.title)\n  \(.body | gsub("\n"; "\n  "))"' "$r")
count=$(jq '[.findings[] | select(.severity == "P0" or .severity == "P1")] | length' "$r")

if [[ "$verdict" == approve && "$count" -eq 0 ]]; then
  head="✅ **Codex review: approved**"
  state=success; desc="Approved"
else
  head="❌ **Codex review: changes requested** ($count blocking)"
  state=failure; desc="Changes requested: $count blocking finding(s)"
fi

comment "$PR" "<!-- agent-review:$SHA -->
$head for \`${SHA:0:7}\`

$(jq -r .summary "$r")

${findings:-_No findings._}"
status "$state" "$desc"
