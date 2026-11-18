# Local reviews

`scripts/run-local.sh` reviews your branch and uncommitted changes before you open a pull
request. It prints the review and changes nothing.

You need:

- **Docker**, running.
- **A clone of this repository, and of redbubble/claude-code-reviews-rules next to it** (as
  `../claude-code-reviews-rules`), or set `CLAUDE_REVIEW_RULES` to where your rules clone is. The
  review uses the helpers in this clone and the rules in that one, whatever branches they're on,
  so `git pull` both to get the latest. The script says when the rules clone isn't on `master`,
  and you can use that to try a rule change on real code before opening its pull request.
- **An Anthropic credential.** If `ANTHROPIC_API_KEY` is set, the script checks it with
  Anthropic and uses it. Otherwise, the first time you run it, it runs `claude setup-token` so
  you can log in with your Claude subscription:
  1. With Claude Code installed on your machine, `setup-token` opens your browser. Without it,
     `setup-token` runs in the container, which can't: open the link it prints yourself.
  2. Log in, and paste the **code** the login page gives you back into `setup-token`.
  3. `setup-token` prints a **token** (`sk-ant-oat01-…`). The script picks it up from the screen
     and stores it in your macOS Keychain (or `~/.config/claude-code-reviews/oauth-token`
     elsewhere) for later runs. You don't need to copy it or `export` it.

  If it can't find the token, it asks you to paste it: the token, not the code. To paste one you
  already have, run `scripts/run-local.sh --set-token`. The token lasts a year; when Anthropic
  rejects it, the script offers to create a new one. A `CLAUDE_CODE_OAUTH_TOKEN` in your
  environment is used instead of the stored one.
- **Optionally, your own Atlassian API token**, so the review can read the Jira issues and
  Confluence pages the change refers to. Create a scoped token at
  https://id.atlassian.com/manage-profile/security/api-tokens with the `read:jira-work` and
  `read:page:confluence` scopes, then set `ATLASSIAN_READ_TOKEN` to the token and
  `ATLASSIAN_EMAIL` to your Atlassian email (in your shell profile, say). Without them the
  review skips Jira and Confluence and says so.
- **The `gh` CLI, logged in** (`gh auth login`). It's optional, but without it the review can't
  read the pull request, if there is one, or other repositories the change refers to.

Then run it from anywhere inside the repository you want reviewed:

```sh
~/src/claude-code-reviews/scripts/run-local.sh                  # against origin's default branch
~/src/claude-code-reviews/scripts/run-local.sh origin/develop   # against another base
```

The first run builds the container image, which takes a minute or two. After that it's reused.
Run `scripts/run-local.sh --rebuild` after changing the `Dockerfile`.

It runs the same review in a container, through `docker-compose.yml`:

- **The image has only the tools**: Node, Claude Code (pinned in the `Dockerfile`), git, gh, jq
  and ripgrep.
- **The rules and helpers are mounted read-only** from your clones, along with
  `scripts/review-in-docker.sh`, which starts Claude inside the container. Editing them needs no
  rebuild.
- **The repository under review is mounted read-only**, and Claude can only read files and run
  read-only git and gh commands. Your token can usually write, so `gh-read` refuses anything but
  GET requests, and `git` in the container (`scripts/git-in-docker.sh`) refuses `--output`, which
  would let `git diff`, `log` or `show` write files. Git also ignores any global config, so a
  written one couldn't make it run a command anyway.
- **Nothing in the repository under review configures Claude.** A branch is untrusted, so Claude
  runs with `--restricted`, which ignores the repository's `.claude/` settings (hooks, permission
  rules, environment, helper commands), and `--strict-mcp-config`, which ignores its `.mcp.json`.
- **Claude can't read your tokens.** They're in its environment, under `/proc`. `--restricted`
  keeps `Read`, `Glob` and `Grep` inside the repository and the rules, symlinks included, and
  `git` refuses `--no-index` and paths outside the repository, which would let `git diff` print
  any file. `gh` and `gh-read` refuse a `--jq` program that reads the environment.
- **It uses the same default model as CI**, read from [`action.yml`](../action.yml), or the model in
  `CLAUDE_REVIEW_MODEL` if you set it in your environment. It limits the findings as CI does
  without `max-findings`, or to `CLAUDE_REVIEW_MAX_FINDINGS` if you set it. Your own Claude Code settings,
  `CLAUDE.md` and plugins aren't in the container, so they don't change the review.
- **What it leaves out**: earlier review threads, hiding summaries and labels, which only apply
  to pull requests.

If you cloned the rules repository before it was renamed from `claude-code-reviews`, point its
clone at the new name:

```sh
git remote set-url origin git@github.com:redbubble/claude-code-reviews-rules.git
```
