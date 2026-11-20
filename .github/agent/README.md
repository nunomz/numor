# Agent pipeline

GitHub issues go in and merged PRs come out. Claude (Opus) implements, Codex
reviews, and a deterministic gate merges.

```
issue + label "agent"  ──► agent-router ──► agent-run (Claude)
                                               │  questions? ──► comment + agent:needs-info ──► your reply resumes it
                                               ▼
                                         PR on agent/issue-N
                                               │
                    CI ─────────────┐          ▼
                                    ├──► agent-gate ◄── agent-review (Codex verdict = commit status)
                                    │      │
             green + approved + in scope ──┼─► squash-merge, issue closes
             green but out of scope/hold ──┼─► agent:needs-human, Telegram ping
             failing, < 3 fix rounds ──────┼─► agent-run fix round
             failing after 3 rounds ───────┴─► agent:needs-human, Telegram ping
```

## Safety model

- Only the repository owner can trigger anything (`agent-router` checks the sender).
- Claude runs with the job's **read-only** `GITHUB_TOKEN` and a checkout without push
  credentials. Codex runs in its read-only sandbox, with no GitHub token in its environment.
- Every write (push, PR, comments, labels, statuses, merge) is done by the scripts in this
  folder using the **agent GitHub App** token. That token is minted after the model has exited.
- The App has no `workflows` permission, so agent branches cannot change `.github/workflows/`.
- This repo is private on GitHub Free, which has no branch protection. `gate.sh` is the merge
  policy: required checks green, Codex `agent/codex-review` status `success`, and the diff
  within `config.json` → `automerge` (size limits and `blocked_paths`).

## Controls

| You do | Effect |
| --- | --- |
| Create an issue from the **Agent task** template (or add `agent` to any issue) | Claude starts |
| Reply on an issue labelled `agent:needs-info` | Claude resumes with your answer |
| Comment `@claude …` on an agent PR | Claude addresses the comment |
| Submit a review with **Request changes** on an agent PR | Claude addresses the review |
| Comment `/review` on an agent PR | Codex reviews again |
| Add `agent:hold` to a PR | No auto-merge; you get pinged when it is green |
| Re-add `agent` to a failed issue | Retry |

Labels: `agent:working`, `agent:needs-info`, `agent:needs-human`, `agent:failed`, `agent:hold`.

## Secrets and variables

| Name | Kind | What |
| --- | --- | --- |
| `AGENT_APP_ID` | variable | ID of the agent GitHub App |
| `AGENT_APP_PRIVATE_KEY` | secret | That App's private key (.pem) |
| `AGENT_GIT_NAME` / `AGENT_GIT_EMAIL` | variables | Commit identity (the App's bot user) |
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | `claude setup-token` (Claude subscription) |
| `CODEX_AUTH_JSON` | secret | ChatGPT-managed Codex `auth.json`; rewritten by `agent-review` after each run |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | secrets | Notifications (optional) |

`CODEX_AUTH_JSON` comes from one `codex login` used **only** by CI, never on a laptop:
refresh tokens rotate, so a login used in two places breaks. Every repo the agent App is
installed on gets the same file, and `agent-review` writes refreshed copies back to all of
them. If reviews start failing with status `error`, re-seed every repo:

```sh
export CODEX_HOME=$(mktemp -d) && printf 'cli_auth_credentials_store = "file"\n' >"$CODEX_HOME/config.toml"
codex login && for r in <repo> <repo> ...; do gh secret set CODEX_AUTH_JSON -R <owner>/$r <"$CODEX_HOME/auth.json"; done
rm -rf "$CODEX_HOME"
```

## Files

- `config.json`: per-repo settings (required checks, auto-merge scope, models, prompt notes).
- `implement-prompt.md` / `implement-schema.json`: Claude's instructions and result shape.
- `review-prompt.md` / `review-schema.json`: Codex's instructions and verdict shape.
- `route.sh`, `run-*.sh`, `review-*.sh`, `gate.sh`, `lib.sh`: the workflow logic.
