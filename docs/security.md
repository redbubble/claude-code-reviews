# Security notes

- **The review only runs in private repositories.** It reads private repositories in both
  organisations, Jira and Confluence, and quotes what it finds in its comments, which anyone can
  read on a public repository. So the action fails the job in a public repository before it
  makes any token or starts Claude, even if the secrets have been made available there.
- **Every repository passes its secrets to this action.** Anyone who can push to `master` here
  can read them in every repository that follows `master`. `master` is protected: every change
  needs a pull request approved by a code owner, with no bypass. A repository that needs more
  control can [pin the logic](configuration.md#pinning-the-logic) to a commit it has read.
- **The actions this one uses are pinned to commit SHAs.** `actions/checkout`,
  `actions/create-github-app-token` and `anthropics/claude-code-action` all run with the
  secrets. A tag such as `@v1` can be moved to other code by whoever controls that repository,
  and that code would then run in every review. A SHA can't be moved. Dependabot
  (`.github/dependabot.yml`) proposes updates as pull requests. Before merging one for
  claude-code-action, check which tools its tag mode adds (`src/modes/tag/index.ts`) against
  `--disallowedTools` in `action.yml`: tag mode once added `git diff` and `git log`, which write
  files with `--output`.
- **The app's private key is the sensitive part.** Anyone holding it can read every repository in
  both organisations. Org secrets are readable by any workflow in a repository that can access
  them, including a `pull_request` workflow on a branch someone just pushed. Limit
  `REVIEW_APP_PRIVATE_KEY` to the repositories that use the review where practical, and rotate it
  (generate a new key, update both org secrets, delete the old key) if it may have leaked.
- **The Datadog API key never reaches Claude.** Only the last step, after the review, gets it,
  and it only sends to `api.datadoghq.com`. A leaked key can send data to Datadog but can't read
  anything from it.
- **Installations by other accounts are harmless.** Making the app installable by any account
  lets others install it on their own accounts. That gives this app read access to *their*
  repositories, never them access to ours. The action always asks for the redbubble or
  teepublic installation by name.
- **The review can't write outside the pull request it reviews.** The app is read-only. The only
  write-capable token is the run's `GITHUB_TOKEN`, scoped to that repository.
- **None of Claude's allowed tools may write a file, push or run arbitrary requests**, whatever
  the run's `GITHUB_TOKEN` can do (`contents: write` is opt-in: see
  [Resolving or minimising earlier findings](configuration.md#resolving-or-minimising-earlier-findings)). There's
  no `git push` or raw `gh api`, and `gh-review-threads` only resolves, replies to or hides
  Claude's own comments and sets its own labels. Check any tool you add for a way to write files:
  `git log`, `git diff` and `git show` write any file with `--output`, and a written
  `~/.gitconfig` makes the next git command run what it names. That's why CI doesn't allow them.
  `gh pr comment` isn't allowed either: its `--body-file` can post any readable file.
- **Tag mode's write tools are switched off.** `track_progress` puts claude-code-action in tag
  mode, which adds `--permission-mode acceptEdits` (file edits and commands such as `touch` and
  `mv` in the workspace) and git add, commit, rm and push tools. `action.yml` passes
  `--permission-mode default` after them, so the later flag wins, and denies those tools with
  `--disallowedTools`.
- **Claude can't read its environment, where the API key and tokens are.** `action.yml` denies
  `Read` under `/proc`, which also covers `Glob`, `Grep` and symlinks to it, and `gh` and `gh-read`
  refuse a `--jq` program that reads the environment. Keep it that way for any tool you add: a
  command that can print its environment or read any file gives the key away, and so does a helper
  that passes Claude's input to `gh api -F`, which reads a value starting with `@` as a file. The
  inline-comment tool posts any text. The GitHub tokens in the job expire when it ends, so a leak
  of one lasts for the rest of the job at most. That's why `contents: write` is opt-in.
- **The read-only tokens are in Claude's environment**, so the helpers it runs can use them. The
  GitHub tokens expire within an hour and are revoked when the job ends. The Atlassian access
  token isn't revoked: it lasts its full hour.
- **The Atlassian client secret never reaches Claude.** Only the hour-long access token made from
  it does, so a leaked token reads what `claude-review-readers` can see for an hour at most.
  Keep that group's access to what reviews need. The client secret is long-lived: like
  `REVIEW_APP_PRIVATE_KEY`, any workflow that can read the org secret can use it, so limit its
  repository access the same way, and replace it if it may have leaked.

## Why `gh-read`

Claude's permission checker rejects any command that expands a variable, so Claude can't run
`GH_TOKEN=$TP_READ_TOKEN gh api ...`, and the action resets `GH_TOKEN` to the run's
`GITHUB_TOKEN` before starting Claude. `gh-read` takes a `gh api` path and picks the read-only
token itself from the organisation in it (`repos/redbubble/...` or `repos/teepublic/...`), so no
command Claude runs contains a token or a variable. It only sends GET requests and allows only
the flags a read needs (`-H`, `--jq`, `--template`, `--cache`, `-i`, `--paginate`, `--slurp`,
`--silent`, `-X GET`), because local reviews give it your own token. `-H` only sets an `Accept`
header for a GitHub JSON, raw, diff or patch response, and a `--jq` program can't read the
environment (`env`, `$ENV`), where the tokens are.

It also reads any other owner's repository, with the redbubble token, as long as it's public, so
the review can read the upstream release notes of a dependency a PR bumps. It checks the
repository's visibility first: in CI the app's token can't see private repositories outside the
two organisations anyway, but locally your own token may. The review reads them this way rather
than with `WebFetch`, so every request still goes only to `api.github.com`, where whoever owns
the repository can't see what was asked. The path can't contain `..` or `%`, which could move a
request out of the repository it names.

Outside redbubble and teepublic, it refuses release-asset downloads (`releases/assets`). Each
asset's download count is public, so a prompt injection could otherwise send data to whoever owns
the repository by choosing which assets to download. The release itself, with its notes, is still
readable.

`gh pr` and `gh issue` go through [`bin/gh`](../bin/gh), first on Claude's PATH. It refuses `--repo`,
URLs and `repo:`, `org:` or `user:` search qualifiers, and always talks to github.com, so those
commands only reach the repository under review. Without it, they would read another owner's
private repository with your token, or send a request to any host. Other repositories go through
`gh-read`. `gh pr list` only takes plain words: gh wraps its search in parentheses before adding
the repository, so parentheses, quotes, qualifiers or `OR` in any of its arguments could search
every repository the token can see.

## Why `atlassian-read`

The review reads the Jira issues and Confluence pages a PR refers to, so it can check the change
does what the issue asks. It can't use an Atlassian MCP server, which needs someone to log in.
Instead it uses a service account's OAuth credential (see
[Atlassian service account](bootstrapping.md#5-atlassian-service-account)). A step before Claude exchanges the
client ID (in [`action.yml`](../action.yml)) and the client secret (an organisation secret, passed
as `atlassian-client-secret`) for an access token that lasts an hour, and only that token is
passed to Claude, as `ATLASSIAN_READ_TOKEN`. There's no login, approval or refresh token: each
run asks for a new token. If the secret is missing or Atlassian refuses it, the step warns and
the review runs without Jira and Confluence.

Claude passes it a reference, never a URL: `atlassian-read jira PROJ-123` or
`atlassian-read confluence <page ID or URL>`. The script builds each request itself, for
Articore's site only (its cloud ID is in the script), and only sends GETs. It turns the issue or
page into text, cuts it at 20,000 characters, and marks it as untrusted content. Locally it uses
your own scoped API token, with basic auth and `ATLASSIAN_EMAIL`, since personal tokens need it;
in CI it sends the access token as a Bearer token.

## Why `gh-review-threads`

Reading and resolving review threads needs GraphQL, and allowing `gh api graphql` would let Claude
run any mutation with the run's write-capable `GITHUB_TOKEN` (close or edit PRs, post reviews).
`gh-review-threads` only lists the PR's threads, and resolves or replies to threads on it that a
Claude reviewer opened. Every command only acts on the PR under review, which `action.yml` passes
in `REVIEW_PR` from the run's event, so a prompt injection can't make it change another PR. It only
accepts thread IDs shaped like GraphQL node IDs, and sends every string to gh with `-f`: with `-F`,
gh reads a value starting with `@` as a file. The only `-F` is the PR number, which GraphQL needs
as an integer and which must first equal `REVIEW_PR`. When the workflow doesn't have `contents:
write`, `resolve` hides the thread's first comment as resolved instead (see [Resolving or
minimising earlier findings](configuration.md#resolving-or-minimising-earlier-findings)).

It also covers two other PR changes the review makes, for the same reason (the alternatives are
raw GraphQL and `gh pr edit`, which can change anything about the PR):

- `hide-summaries` hides earlier Claude summaries as outdated, so only the latest one stays
  expanded. A summary is a comment by a Claude reviewer with a line starting `Rules applied: `,
  which every summary ends with (in a collapsed block from rules v0.15).
- `labels` sets the PR's `claude-review:*` labels (`important`, `security`, `rollback-risk`,
  `needs-tests`, `performance`, `cost`, `rules-weakened`) to the ones that match its open
  findings, creating any the repository doesn't have yet. It never touches other labels. When
  to apply each is in the rules.
