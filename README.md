# Claude Code Reviews

A GitHub Action that reviews pull requests in Articore repositories with Claude Code.

This repository holds the logic: the action, its helper commands and the local runner. The review
rules are in the private
[redbubble/claude-code-reviews-rules](https://github.com/redbubble/claude-code-reviews-rules),
and so are the architecture decision records for both repositories. The action is built for
Articore's repositories, and won't work elsewhere: it needs our GitHub App, secrets and rules.

## Usage

Add `.github/workflows/claude-code-review.yml` to the repository:

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]

permissions:
  contents: read
  pull-requests: write
  issues: read

jobs:
  claude-review:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    concurrency:
      group: claude-review-${{ github.event.pull_request.number }}
      cancel-in-progress: true
    steps:
      - uses: redbubble/claude-code-reviews@master
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          app-private-key: ${{ secrets.REVIEW_APP_PRIVATE_KEY }}
          atlassian-client-secret: ${{ secrets.ATLASSIAN_CLIENT_SECRET }}
```

Then:

1. Optionally, add a `REVIEW.md` at the repository root with rules the baseline doesn't cover
   (see [A repository's own rules](#a-repositorys-own-rules)). Without one, the baseline applies
   on its own.
2. Add a `CODEOWNERS` entry covering `REVIEW.md` and `.github/workflows/`, so changes that weaken
   the review need an owner's approval.
3. Open a pull request. The review runs on that PR, so you can check the setup works before
   merging.

With this workflow, a review runs when a PR is opened, reopened, marked ready for review, or
pushed to, and a new push cancels a review still running on the previous one. To change when it
runs, see [Configuring the workflow](#configuring-the-workflow). Draft PRs aren't reviewed until
they're marked ready.

This relies on the one-time setup in [CI Bootstrapping](#ci-bootstrapping).

### Pull requests that aren't reviewed

Pull requests that only hold an architecture decision record aren't reviewed: they're discussed
on the PR instead. A PR counts as one when its branch name starts with `adr-` and every file it
changes, including a renamed file's old name, is under `docs/adr/`. Any other change from an
`adr-` branch is reviewed as usual. A PR the review skips still passes the `claude-review` check,
so a required check doesn't block it.

### A repository's own rules

A `REVIEW.md` at the repository root adds rules for that repository on top of the baseline, and
takes precedence where the two conflict. Keep it short, and only add what the baseline doesn't
cover:

```markdown
# Review instructions

Rules specific to this repository. They apply on top of the Articore review baseline and take
precedence where the two conflict.

## Context
- What this service does, and what data classification it handles (Level 1-4).
- Internet-facing? Handles payments, auth or customer PII?

## What Important also means here
- e.g. "Any change to `app/payments/` without a request spec is Important."

## Always check
- e.g. "New Sidekiq jobs must be idempotent and set `retry:` explicitly."

## Do not report
- e.g. "`src/gen/` is generated from the OpenAPI spec."
```

## Configuring the workflow

Each of these is a change to the workflow in [Usage](#usage), made through a pull request like any
other workflow change.

### Reviewing only when asked

To review a pull request only when someone asks for it, replace the `on:` block with a `labeled`
trigger, and skip every other label:

```yaml
on:
  pull_request:
    types: [labeled]

jobs:
  claude-review:
    if: github.event.label.name == 'claude-review'
    # ...the rest of the job as in Usage
```

Add the `claude-review` label to a pull request to review it. To review a later push, remove the
label and add it again. The `if:` matters: without it, adding any other label starts a job that
cancels a review in progress.

### Pinning the logic

`@master` runs the latest action on every review. To choose when the action changes, use a full
40-character commit SHA from this repository's `master` instead:

```yaml
      - uses: redbubble/claude-code-reviews@0123456789abcdef0123456789abcdef01234567
```

We keep the action working with every rules version, so most repositories leave this on
`master` and pin the rules instead.

### Pinning the rules

The rules follow `master` of redbubble/claude-code-reviews-rules by default, so a rule change
applies everywhere on the next review. To choose when your repository takes new rules, pin a
commit with `rules-ref`:

```yaml
        with:
          # ...the inputs as in Usage
          rules-ref: 0123456789abcdef0123456789abcdef01234567  # review baseline v0.11
```

Use the merge commit on `master` of the baseline version you want: the version is in the title of
`RULES.md` and in the commit message. Use the full 40-character SHA: a short one won't check out.
Say which version it is in a comment.

To update, change the SHA in a pull request. The review on that pull request uses the new rules,
so you see how they behave on your code before merging. To go back to following every change,
remove `rules-ref`. A pinned repository gets no rule changes until it updates, fixes included,
and nothing tells it a newer version exists.

### Choosing the model

The review uses `claude-opus-5-5`. To use another model, add `model` with a model ID:

```yaml
        with:
          # ...the inputs as in Usage
          model: claude-sonnet-5-5
```

The value is pasted into `claude_args`, which the action splits into separate flags, so the
review fails unless it's a single model ID with no spaces or quotes. Otherwise it could add flags
such as a wider `--allowedTools`. A model ID that doesn't exist also fails the review rather than
falling back to the default.

### Resolving or minimising earlier findings

When a later push fixes an issue the review raised, the review closes its thread. How it closes it
depends on one permission in the workflow, and each repository chooses:

| | `contents: read` (the default in Usage) | `contents: write` |
| --- | --- | --- |
| A fixed finding's thread | Stays open. Its first comment is hidden as *Resolved*, so it collapses on the PR. | Is resolved. |
| "Require conversation resolution before merging" | Each fixed thread still needs a person to resolve it before the PR can merge. | Fixed threads no longer block the merge. |
| If a prompt injection leaks the run's token | Whoever has it can comment on, label or edit pull requests in this repository until the job ends. | They can also push branches and commits to this repository until the job ends. |

GitHub won't resolve threads without `contents: write`. The review can't push with it: none of its
allowed tools write files or push. But it can read its own environment and post what it reads,
so a prompt injection in what it reviews (a PR description, a dependency's release notes, code
from another repository) could leak the token while the job runs.

To switch, change `contents: read` to `contents: write`. Keep `contents: read` if branch
protection doesn't require resolved conversations, or if a leaked token's push access matters
more to you than clicking *Resolve* on fixed threads.

## How it works

On every pull request it reviews, the action:

1. **Creates read-only tokens** from the review GitHub App, one for each organisation, and passes
   them to Claude as `RB_READ_TOKEN` (redbubble) and `TP_READ_TOKEN` (teepublic). It also
   exchanges the Atlassian service account's OAuth credential at `auth.atlassian.com` for an
   access token that lasts an hour, passed as `ATLASSIAN_READ_TOKEN` (see
   [Why `atlassian-read`](#why-atlassian-read)).
2. **Checks out the rules** from redbubble/claude-code-reviews-rules, at `master` or the
   [pinned](#pinning-the-rules) commit, into `.claude-code-reviews/` with the redbubble token. If
   the checkout fails or `RULES.md` is missing, the job fails and there's no review. It puts this
   action's [`bin/`](bin/) on the `PATH`.
3. **Runs `anthropics/claude-code-action`.** Claude reads `RULES.md` first, then the other rule
   files in the order `RULES.md` gives, and reviews the PR against them plus the repository's own
   `REVIEW.md`. It reads other repositories in either organisation, and public repositories
   anywhere on GitHub (upstream changelogs and release notes, say), with
   [`gh-read`](bin/gh-read) when the PR refers to them, the Jira issues and Confluence pages it
   refers to with [`atlassian-read`](bin/atlassian-read), and handles its earlier review threads
   with [`gh-review-threads`](bin/gh-review-threads).
4. **Posts inline comments and a summary** as `github-actions[bot]`, using the run's own
   `GITHUB_TOKEN`. It hides the earlier summaries and sets the PR's `claude-review:*` labels to
   match its open findings.

Changes merged to `master`, here or in the rules repository, reach every repository that follows
`master` on its next review.

### Local reviews

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
- **It uses the same default model as CI**, read from [`action.yml`](action.yml), or the model in
  `CLAUDE_REVIEW_MODEL` if you set it in your environment. Your own Claude Code settings,
  `CLAUDE.md` and plugins aren't in the container, so they don't change the review.
- **What it leaves out**: earlier review threads, hiding summaries and labels, which only apply
  to pull requests.

If you cloned the rules repository before it was renamed from `claude-code-reviews`, point its
clone at the new name:

```sh
git remote set-url origin git@github.com:redbubble/claude-code-reviews-rules.git
```

### Why `gh-read`

Claude's permission checker rejects any command that expands a variable, so Claude can't run
`GH_TOKEN=$TP_READ_TOKEN gh api ...`, and the action resets `GH_TOKEN` to the run's
`GITHUB_TOKEN` before starting Claude. `gh-read` takes a `gh api` path and picks the read-only
token itself from the organisation in it (`repos/redbubble/...` or `repos/teepublic/...`), so no
command Claude runs contains a token or a variable. It only sends GET requests and allows only
the flags a read needs (`-H`, `--jq`, `--template`, `--cache`, `-i`, `--paginate`, `--slurp`,
`--silent`, `-X GET`), because local reviews give it your own token.

It also reads any other owner's repository, with the redbubble token, as long as it's public, so
the review can read the upstream release notes of a dependency a PR bumps. It checks the
repository's visibility first: in CI the app's token can't see private repositories outside the
two organisations anyway, but locally your own token may. The review reads them this way rather
than with `WebFetch`, so every request still goes only to `api.github.com`, where whoever owns
the repository can't see what was asked. The path can't contain `..` or `%`, which could move a
request out of the repository it names.

### Why `atlassian-read`

The review reads the Jira issues and Confluence pages a PR refers to, so it can check the change
does what the issue asks. It can't use an Atlassian MCP server, which needs someone to log in.
Instead it uses a service account's OAuth credential (see
[Atlassian service account](#5-atlassian-service-account)). A step before Claude exchanges the
client ID (in [`action.yml`](action.yml)) and the client secret (an organisation secret, passed
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

### Why `gh-review-threads`

Reading and resolving review threads needs GraphQL, and allowing `gh api graphql` would let Claude
run any mutation with the run's write-capable `GITHUB_TOKEN` (close or edit PRs, post reviews).
`gh-review-threads` only lists the PR's threads, and resolves or replies to threads in the same
repository that a Claude reviewer opened. When the workflow doesn't have `contents: write`,
`resolve` hides the thread's first comment as resolved instead (see
[Resolving or minimising earlier findings](#resolving-or-minimising-earlier-findings)).

It also covers two other PR changes the review makes, for the same reason (the alternatives are
raw GraphQL and `gh pr edit`, which can change anything about the PR):

- `hide-summaries` hides earlier Claude summaries as outdated, so only the latest one stays
  expanded. A summary is a comment by a Claude reviewer with a line starting `Rules applied: `,
  which every summary ends with.
- `labels` sets the PR's `claude-review:*` labels (`important`, `security`, `rollback-risk`,
  `needs-tests`, `performance`, `cost`, `rules-weakened`) to the ones that match its open
  findings, creating any the repository doesn't have yet. It never touches other labels. When
  to apply each is in the rules.

## Repository layout

| Path | Purpose |
| --- | --- |
| `action.yml` | The action: decides whether to review, gets the tokens, checks out the rules and runs Claude. |
| `bin/gh-read` | `gh api` for other repositories, with the right organisation's read-only token, and for public repositories anywhere on GitHub. |
| `bin/atlassian-read` | Reads one Jira issue or Confluence page, as text, with the review's read-only Atlassian token. |
| `bin/gh-review-threads` | Lists the PR's review threads, and resolves or replies to Claude's own. Hides Claude's earlier summaries and sets the PR's `claude-review:*` labels. |
| `Dockerfile`, `docker-compose.yml` | The container local reviews run in: tools only. |
| `scripts/run-local.sh` | Runs a local review of the repository you're in. |
| `scripts/review-in-docker.sh` | Runs inside the container: starts Claude on the review. |
| `scripts/git-in-docker.sh` | `git` inside the container: refuses `--output`, so git can't write files. |

## Changing the action

- Changes go through a pull request, approved by a code owner. This repository isn't reviewed by
  the action in CI: it's public, and the organisation secrets are only available to private
  repositories. To have Claude review a change, run a [local review](#local-reviews) on its
  branch.
- Keep the action working with every rules version a repository may have pinned. Add helpers and
  inputs; don't remove or change them under rules that use them.
- Claude can only run a new helper in `bin/` once it's in `--allowedTools` in `action.yml`. Check
  it for a way to write files first (see [Security notes](#security-notes)).
- Changes to the rules go to redbubble/claude-code-reviews-rules, and so do decisions about
  either repository, as ADRs.

## CI Bootstrapping

In order to access repositories (read only access) in both our orgs, we need to create and install
a custom GH app. You'll need an org admin in each organisation for that.

### 1. The review GitHub App

The app already exists and is owned by the **teepublic** organisation:
**[claude-code-review-org-reader](https://github.com/organizations/teepublic/settings/apps/claude-code-review-org-reader)**
(settings, for teepublic owners and app managers; public page:
https://github.com/apps/claude-code-review-org-reader). It can't be moved to redbubble while it's
public, and it has to be public to be installed on both organisations.

The table below is how it's configured, for reference or if it ever needs recreating via
*Settings → Developer settings → GitHub Apps → New GitHub App*.

| Setting | Value |
| --- | --- |
| Webhook | Uncheck *Active* |
| Repository permissions | **Contents: Read-only** · **Metadata: Read-only** (mandatory) · **Pull requests: Read-only** · **Issues: Read-only** |
| Organization and account permissions | None |
| Where can this GitHub App be installed? | **Any account**, so it can be installed on both organisations |

After creating it:

1. Copy the **App ID** from its settings page into both `app-id:` lines of
   [`action.yml`](action.yml). The ID isn't secret.
2. Under *Private keys*, **generate a private key**. This downloads a `.pem` file: you'll store it
   as a secret in step 3, then delete the local file.

The app never posts anything: comments use each run's `GITHUB_TOKEN`.

### 2. Install the app on both organisations

From the [app's public page](https://github.com/apps/claude-code-review-org-reader), install it
on **redbubble** and on **teepublic**, choosing **All repositories** for each. That lets Claude
read any repository a PR refers to, and the redbubble installation covers
redbubble/claude-code-reviews-rules, which every review reads the rules from.

### 3. Add the secrets to both organisations

In **each** of redbubble and teepublic: *Settings → Secrets and variables → Actions →
New organization secret*:

| Name | Value |
| --- | --- |
| `REVIEW_APP_PRIVATE_KEY` | The whole contents of the `.pem` file, including the `BEGIN`/`END` lines |
| `ANTHROPIC_API_KEY` | Anthropic API key |

For *Repository access*, choose the repositories that use the review (or all private
repositories).

To review Dependabot PRs too, add both again under *Secrets and variables → Dependabot*.
Dependabot runs can't read Actions secrets, so without them the review fails on every Dependabot PR.

### 4. Allow the actions

If an organisation restricts which actions can run (*Settings → Actions → General*), allow
`redbubble/claude-code-reviews`, `anthropics/claude-code-action`,
`actions/create-github-app-token` and `actions/checkout`.

### 5. Atlassian service account

For `atlassian-read`. An Atlassian organisation admin sets this up in admin.atlassian.com.

1. **A group for its access**: under *Directory → Groups*, create `claude-review-readers`. Give
   it *Browse Projects* in the Jira permission schemes of the projects reviews should read, and
   *View* in the Confluence spaces they should read. Leave out restricted spaces: whatever this
   group can see may end up summarised in a PR comment.
2. **The service account**: *Directory → Service accounts → Create a service account*, named
   e.g. `claudecodereview`, with a description naming its owner and this repository. Give it
   Jira and Confluence access with the basic user role, and add it to `claude-review-readers`.
3. **Its OAuth credential**: on the service account, *Create credentials → OAuth 2.0*, with
   exactly the scopes `read:jira-work` and `read:page:confluence` (a granular scope: search for
   it). Scopes can't be changed after it's created. Copy the client ID and client secret: they're
   shown once. The client ID isn't secret: put it in the `CLIENT_ID:` line of
   [`action.yml`](action.yml).
4. **Check it**, with an issue and a page the group can see. Get an access token, then read
   both with it. 401 means a wrong scope, and 404 a wrong cloud ID or no access to that issue or
   page:

   ```sh
   curl -X POST https://auth.atlassian.com/oauth/token -d grant_type=client_credentials -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET"
   curl -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.atlassian.com/ex/jira/<cloud ID>/rest/api/3/issue/PROJ-123?fields=summary"
   curl -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.atlassian.com/ex/confluence/<cloud ID>/wiki/api/v2/pages/<page ID>"
   ```

   The cloud ID is in `atlassian-read`, or at `https://<site>.atlassian.net/_edge/tenant_info`.
5. **Store the client secret** in each of redbubble and teepublic as the organisation secret
   `ATLASSIAN_CLIENT_SECRET` (and under *Dependabot*, as in step 3).
6. **To replace it** (it may have leaked, or its owner left): create a new credential, update
   the secret in both organisations and the client ID in `action.yml`, then revoke the old one.
   Repositories that follow `master` get the new client ID on their next review.

## Security notes

- **Every repository passes its secrets to this action.** Anyone who can push to `master` here
  can read them in every repository that follows `master`. `master` is protected: every change
  needs a pull request approved by a code owner, with no bypass. A repository that needs more
  control can [pin the logic](#pinning-the-logic) to a commit it has read.
- **The app's private key is the sensitive part.** Anyone holding it can read every repository in
  both organisations. Org secrets are readable by any workflow in a repository that can access
  them, including a `pull_request` workflow on a branch someone just pushed. Limit
  `REVIEW_APP_PRIVATE_KEY` to the repositories that use the review where practical, and rotate it
  (generate a new key, update both org secrets, delete the old key) if it may have leaked.
- **Installations by other accounts are harmless.** Making the app installable by any account
  lets others install it on their own accounts. That gives this app read access to *their*
  repositories, never them access to ours. The action always asks for the redbubble or
  teepublic installation by name.
- **The review can't write outside the pull request it reviews.** The app is read-only. The only
  write-capable token is the run's `GITHUB_TOKEN`, scoped to that repository.
- **None of Claude's allowed tools may write a file, push or run arbitrary requests**, whatever
  the run's `GITHUB_TOKEN` can do (`contents: write` is opt-in: see
  [Resolving or minimising earlier findings](#resolving-or-minimising-earlier-findings)). There's
  no `git push` or raw `gh api`, and `gh-review-threads` only resolves, replies to or hides
  Claude's own comments and sets its own labels. Check any tool you add for a way to write files:
  `git log`, `git diff` and `git show` write any file with `--output`, and a written
  `~/.gitconfig` makes the next git command run what it names. That's why CI doesn't allow them.
  `gh pr comment` isn't allowed either: its `--body-file` can post any readable file.
- **Claude can read the run's tokens and post them.** `Read` reaches its own process
  environment, and the inline-comment tool posts any text. The GitHub tokens in the job expire
  when it ends, so a leak of one through a prompt injection lasts for the rest of the job at
  most. That's why `contents: write` is opt-in.
- **Claude can see the read-only tokens.** They're in its environment so it can use them. The
  GitHub tokens expire within an hour and are revoked when the job ends. The Atlassian access
  token isn't revoked: it lasts its full hour.
- **The Atlassian client secret never reaches Claude.** Only the hour-long access token made from
  it does, so a leaked token reads what `claude-review-readers` can see for an hour at most.
  Keep that group's access to what reviews need. The client secret is long-lived: like
  `REVIEW_APP_PRIVATE_KEY`, any workflow that can read the org secret can use it, so limit its
  repository access the same way, and replace it if it may have leaked.
