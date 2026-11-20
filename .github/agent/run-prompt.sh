#!/usr/bin/env bash
# agent-run: render Claude's prompt and CLI arguments into step outputs.
# Env: ISSUE, PR, MODE, REASON, BRANCH + lib.sh requirements.
# Outputs: prompt, claude_args

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

render() { # placeholder value  (literal replacement, safe for any characters)
  local k=$1 v=$2
  prompt=${prompt//"{{$k}}"/"$v"}
}

prompt=$(cat "$AGENT_DIR/implement-prompt.md")
render REPO "$REPO"
render OWNER "${REPO%%/*}"
render BRANCH "$BRANCH"
render BASE "$(cfg .base_branch)"
render MODE "$MODE"
render ISSUE "$ISSUE"
render PR "${PR:-none yet}"
reason=""
[[ -n "${REASON:-}" ]] && reason=$'\n'"Note from the pipeline: ${REASON}"
render REASON "$reason"
render VERIFY "$(cfg .implement.verify)"
notes=$(cfg '.implement.notes // empty')
[[ -n "$notes" ]] && notes=$'\n## Repository-specific notes\n\n'"$notes"
render NOTES "$notes"

schema=$(jq -c . "$AGENT_DIR/implement-schema.json")
model=$(cfg .implement.model)
max_turns=$(cfg .implement.max_turns)

delim="EOF_$(openssl rand -hex 16)"
{
  echo "prompt<<$delim"; echo "$prompt"; echo "$delim"
  echo "claude_args<<$delim"
  echo "--model $model"
  echo "--max-turns $max_turns"
  echo "--allowedTools Bash,Read,Edit,MultiEdit,Write,Glob,Grep,LS,TodoWrite,Task,WebFetch,WebSearch"
  # Belt and braces: Claude's token is read-only anyway.
  echo "--disallowedTools \"Bash(git push:*)\" \"Bash(gh pr merge:*)\" \"Bash(gh pr create:*)\""
  echo "--json-schema '$schema'"
  echo "$delim"
} >>"$GITHUB_OUTPUT"
