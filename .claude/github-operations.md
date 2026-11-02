# GitHub operations

Read before the first GitHub write (CLAUDE.md, "GitHub operations"). Local sessions use `gh`; cloud sessions have no `gh` and use the GitHub MCP tools (load them via ToolSearch). Same operation, same rules.

| Operation | Local (`gh`) | Cloud session (MCP / session tools) |
|---|---|---|
| Read an issue and its comments | `gh issue view <n> --comments` | `mcp__github__issue_read` method `get`, then `get_comments` |
| Comment on an issue or PR | `gh issue comment` / `gh pr comment` | `mcp__github__add_issue_comment` (PR number as `issue_number`) |
| Change labels | `gh issue edit --add-label/--remove-label` | `mcp__github__issue_write` method `update` with `labels`: **replaces the whole set**, so read the current labels first (`issue_read` method `get_labels`) |
| Create a sub-issue and link it | `gh issue create`, then `gh api -X POST repos/pklnx/dokumentum/issues/N/sub_issues -F sub_issue_id=<issue .id>` | `mcp__github__issue_write` method `create` with `parent_issue_number: N`; for an existing issue `mcp__github__sub_issue_write` method `add` with `sub_issue_id` (the issue's id, not its number) |
| Open a PR with a label | `gh pr create --label <l>` | `mcp__github__create_pull_request` (cannot set labels), then `mcp__github__issue_write` method `update` with `labels` on the PR number |
| Read a PR and its diff | `gh pr view`, `gh pr diff` | `mcp__github__pull_request_read` method `get`, `get_diff` (`get_files` for the file list) |
| Read check status once | `gh pr checks <n>` | `mcp__github__pull_request_read` method `get_check_runs` (plus `get_status` for commit statuses) |
| Coordinator waits for CI (first wait until the checks appear, in both columns) | background `gh pr checks <n> --watch --interval 120 >/dev/null 2>&1; gh pr checks <n>` | `mcp__claude-code-remote__subscribe_pr_activity` on the PR wakes the coordinator; optionally one `mcp__claude-code-remote__send_later` check-in that reads `get_check_runs` as a safety net; `unsubscribe_pr_activity` after merge or close |
| Merge | `gh pr merge <n> --squash --match-head-commit <sha>` | `mcp__github__merge_pull_request` with `merge_method: squash`, `expectedHeadSha: <sha>` |
| Create a milestone | `gh api -X POST repos/pklnx/dokumentum/milestones -f title=<title> -f description='<goal>'` | no MCP tool: REST fallback (below), `POST repos/pklnx/dokumentum/milestones` with `{"title":"<title>","description":"<goal>"}` |
| Rename or close a milestone | `gh api -X PATCH repos/pklnx/dokumentum/milestones/<number> -f title=<title>` / `-f state=closed` | REST fallback, `PATCH repos/pklnx/dokumentum/milestones/<number>` with `{"state":"closed"}` or `{"title":"<title>"}` |
| List milestones (with numbers) | `gh api 'repos/pklnx/dokumentum/milestones?state=all'` | REST fallback, `GET repos/pklnx/dokumentum/milestones?state=all` |
| Assign an issue or PR to a milestone | `gh issue edit <n> --milestone <title>` (`gh pr edit` for a PR) | `mcp__github__issue_write` method `update` with `milestone`: the milestone **number**, not its title |

## REST fallback in cloud sessions
Rule: [pklnx/dev-process `decisions.md` G26](https://github.com/pklnx/dev-process/blob/main/decisions.md) (green: the channel only; each operation keeps its own tier, and a refusal by policy stays undone and is reported).

Maintainer decision (2026-11-01): agents perform GitHub operations that have no MCP tool themselves (milestones above); they do not hand them to the maintainer. In a cloud session without `gh`, call the REST API with the session's token, only for the repositories in the session's scope:

```bash
curl -s -X POST -H "Content-Type: application/json" -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/pklnx/dokumentum/milestones -d '{"title":"<title>","description":"<goal>"}'
```

- The `Content-Type: application/json` header is required (the proxy refuses a body without it). Build JSON bodies with a JSON encoder, not by hand.
- Use it only where no MCP tool covers the operation; everything else stays on the MCP tools. Never print or log the token.
- GraphQL (`gh` subcommands other than `gh api`) is refused in cloud sessions; REST is not.
