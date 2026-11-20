#!/usr/bin/env bash
# agent-router: turns the owner's GitHub activity into agent-run / agent-review
# dispatches. Runs with the workflow's GITHUB_TOKEN: label and comment writes
# made with it never trigger other workflows, so the router cannot loop.
#
# Env: EVENT_NAME, EVENT_PATH (the webhook payload) + lib.sh requirements.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ev() { jq -r "$1" "$EVENT_PATH"; }

case "$EVENT_NAME" in
  issues)
    # Label "agent" added to an issue: start (or restart) the work.
    n=$(ev .issue.number)
    if has_label "$n" agent:working; then
      echo "Issue #$n is already being worked on."; exit 0
    fi
    remove_labels "$n" agent:failed agent:needs-info
    add_labels "$n" agent:working
    # Restart on an issue that already has a PR: continue on that PR.
    pr=$(pr_for_branch "agent/issue-$n")
    if [[ -n "$pr" ]]; then
      dispatch_run "$n" fix "$pr" "The owner re-applied the agent label. Re-read the issue and PR conversation and continue."
    else
      dispatch_run "$n" implement
    fi
    notify "🛠 Claude started on #$n: $(ev .issue.title)
$(issue_url "$n")"
    ;;

  issue_comment)
    n=$(ev .issue.number)
    body=$(ev .comment.body)
    if [[ "$(ev '.issue.pull_request != null')" == true ]]; then
      branch=$(gh pr view "$n" -R "$REPO" --json headRefName --jq .headRefName)
      issue=$(issue_from_branch "$branch")
      [[ -n "$issue" ]] || { echo "PR #$n is not an agent PR."; exit 0; }
      if [[ "$body" == /review* ]]; then
        gh workflow run agent-review.yml -R "$REPO" --ref "$(cfg .base_branch)" -f pr="$n"
        notify "🔍 Re-running Codex review on PR #$n
$(pr_url "$n")"
      elif [[ "$body" == *@claude* ]]; then
        add_labels "$issue" agent:working
        dispatch_run "$issue" fix "$n" "The owner asked for changes in PR comment $(ev .comment.html_url). Do what it asks."
        notify "🛠 Claude is addressing your comment on PR #$n
$(pr_url "$n")"
      fi
    else
      # The owner answered the agent's questions on the issue.
      has_label "$n" agent:needs-info || { echo "Issue #$n is not waiting for info."; exit 0; }
      remove_labels "$n" agent:needs-info
      add_labels "$n" agent:working
      pr=$(pr_for_branch "agent/issue-$n")
      if [[ -n "$pr" ]]; then
        dispatch_run "$n" fix "$pr" "The owner answered your questions on the issue (latest comments). Continue."
      else
        dispatch_run "$n" resume
      fi
      notify "▶️ Claude resumed #$n with your answer
$(issue_url "$n")"
    fi
    ;;

  pull_request_review)
    # The owner requested changes in a review on an agent PR.
    n=$(ev .pull_request.number)
    issue=$(issue_from_branch "$(ev .pull_request.head.ref)")
    [[ -n "$issue" ]] || exit 0
    add_labels "$issue" agent:working
    dispatch_run "$issue" fix "$n" "The owner submitted a review requesting changes: $(ev .review.html_url). Address every point."
    notify "🛠 Claude is addressing your review on PR #$n
$(pr_url "$n")"
    ;;

  *)
    echo "Unhandled event $EVENT_NAME"; exit 1 ;;
esac
