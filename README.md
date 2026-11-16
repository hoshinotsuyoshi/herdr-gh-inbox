# herdr-gh-inbox

A terminal inbox for GitHub notifications. In [Herdr](https://herdr.dev), it reports attention through OSC 7501, so a review request or mention appears in the Agents list and marks its space and tab.

## Requirements

- Ruby 3.4 or later (standard library only), or a binary compiled with [Spinel](https://github.com/matz/spinel).
- [GitHub CLI](https://cli.github.com/) (`gh`) on `PATH`, logged in with a classic token that has `notifications` or `repo` scope. Subject bodies may also need `repo` scope. The `g` and `a` keys also require a running Herdr.app and `herdr-app` on `PATH`.
- A terminal with TTY input and output for the interactive view. Without one, the program prints one plain-text list and exits.

No token is saved by this program. It calls `gh api` with the user's existing `gh` authentication.

## Install and run

From this checkout:

```sh
./bin/herdr-gh-inbox
./bin/herdr-gh-inbox --json
```

To use the command name in Herdr, put the script or a compiled binary on `PATH`, for example by linking `bin/herdr-gh-inbox` into `~/.local/bin`. A release archive contains a native binary, `LICENSE`, and `THIRD_PARTY_NOTICES`.

For a visible Herdr tab, use the app's command (the `argv` program must be on its `PATH`):

```sh
herdr-app do tab.new --name "GitHub inbox" --argv '["herdr-gh-inbox"]'
```

Or run it with `hc` and adopt the terminal into a known space and tab:

```sh
hc run --bg --keep --name gh --label herdr.space=<space-id> --label herdr.tab=<tab-id> -- herdr-gh-inbox
hc get gh --json
hc read gh --lines 0
```

Use IDs from `herdr-app ls`; on a remote machine, strip the machine prefix before writing labels there. A terminal without these labels can report agent status to `hc` but will not appear in Herdr's spaces and tabs.

## Inbox behavior

The list contains unread, participating notifications from `GET /notifications?participating=true`, across all pages. Reasons that need a person are grouped first and shown in a bright color; other unread notifications follow in a dim color. Rows align the short repository name, subject type, reason, relative update age, and title, including Japanese text. Selecting a row loads its body and latest comment in the side or lower pane; the result is cached while the notification remains in the inbox. The footer shows the last successful check and the time until the next poll, or an error reason.

The status is `blocked:kind=question` if any unread notification has one of these reasons: `approval_requested`, `assign`, `member_feature_requested`, `mention`, `review_requested`, `security_alert`, or `team_mention`. These ask for a decision, response, or attention to security. Other unread notifications give `done`; an empty inbox gives `idle`. An authentication failure gives `blocked:kind=auth`; other fetch failures give `error`. The program reports only status changes and does not report `working` for each poll.

It polls no faster than every 60 seconds and honors a longer `X-Poll-Interval`. After a successful response it sends `If-Modified-Since` with GitHub's `Last-Modified`; a 304 leaves the list and status alone. `R` makes an immediate manual request. `r` and `d` show a pending state immediately while the API request runs in the background. Repeated mark keys are ignored, including after the request finishes. On success the item disappears and no other item is selected; press `j` or `k` to choose one. On failure it stays in the list with an error. `q` waits for an in-flight mark to finish.

| Key | Action |
| --- | --- |
| `j` / `k` | Select next / previous notification |
| `Enter` | Show the selected subject body and latest comment (also loaded on selection) |
| `r` | Mark selected thread read with `PATCH /notifications/threads/{id}` |
| `d` | Mark selected thread done with `DELETE /notifications/threads/{id}` |
| `o` | Open the selected issue, pull request, or repository with `gh browse` |
| `g` | Switch to the Herdr space containing that repository |
| `a` | Open a Claude Code tab in that repository, with a review task |
| `R` | Refresh now |
| `q` | Quit |

`--json` prints each unread notification as one JSON object per line, with no terminal control sequences. It is suitable for an agent or a pipeline.

## Herdr navigation

`g` reads `herdr-app ls` and considers local spaces' `folder` values. For each folder it walks up to the clone's `.git` directory (including Git worktrees), reads the GitHub remote URL, and compares its full `owner/repo` with the notification's repository. A matching space is selected with `space.select {id}`. A space with only the same short repo name does not count. Remote-machine spaces and folders without a matching GitHub remote are skipped. If a clone exists but has no matching space, `g` reports that; if no clone can be found, it reports that instead.

`a` uses the same clone lookup and calls `tab.new {folder, argv, task}`. If a matching space exists, it passes its ID as `space`; otherwise the new tab opens in Herdr's currently selected space with the clone root as `folder`. It never launches an agent when the clone location cannot be verified. For a local clone that is not in a Herdr space, set `HERDR_GH_INBOX_REPO_DIRS` to a JSON object such as `{"example-org/app":"/path/to/app"}`. Each mapped path is checked against its GitHub remote before use.

The default agent is `argv: ["claude"]`. The default task is `Please review this %{type}: %{url}`, where `%{type}` is `PR`, `issue`, or `notification`. Set `HERDR_GH_INBOX_AGENT_ARGV` to a JSON string array and `HERDR_GH_INBOX_TASK_TEMPLATE` to change them. The template supports `%{type}`, `%{url}`, and `%{repo}`. For example:

```sh
export HERDR_GH_INBOX_AGENT_ARGV='["codex"]'
export HERDR_GH_INBOX_TASK_TEMPLATE='Review %{repo}: %{url}'
```

## Development

```sh
ruby -w test/inbox_test.rb
spinel bin/herdr-gh-inbox -o herdr-gh-inbox
INBOX_BIN=./herdr-gh-inbox ruby -w test/inbox_test.rb
```

Tests use an injected fake `gh` command (`HERDR_GH_INBOX_GH`) and never contact GitHub. CI tests Ruby 3.4 and 4.0 and a Spinel binary. Spinel is pinned in `.spinel-version`. A `v*` tag builds Linux x86_64 and arm64 and macOS arm64 binaries, then creates a release. GitHub Actions dependencies are recorded in `.github/workflows/actions.lock` (update with `gh actions-lock` after changing a `uses:` line).

## License

MIT, see [LICENSE](LICENSE). Binary dependencies are listed in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
