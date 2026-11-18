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
          datadog-api-key: ${{ secrets.DATADOG_API_KEY }}
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
pushed to, and a new push cancels a review still running on the previous one. Changing a PR's
base branch doesn't start one: the check keeps the result of the review against the old base,
whose diff may have been much smaller. After changing the base, push a commit, or close and reopen
the PR, to review it against the new one. (claude-code-action can't run on the `edited` event a
base change sends.) To change when it
runs, see [Configuring the workflow](docs/configuration.md). Draft PRs aren't reviewed until
they're marked ready, unless the run comes from a label being added (see
[Reviewing only when asked](docs/configuration.md#reviewing-only-when-asked)).

This relies on the one-time setup in [CI Bootstrapping](docs/bootstrapping.md).

### Pull requests that aren't reviewed

Pull requests that only hold an architecture decision record aren't reviewed: they're discussed on
the PR instead. A PR counts as one when its branch name starts with `adr-`, it's against the
repository's default branch, and every file it changes, including a renamed file's old name, is
under `docs/adr/`. Any other change from an `adr-` branch is reviewed as usual. A PR the review
skips still passes the `claude-review` check (`claude-review / review` with the
[reusable workflow](docs/configuration.md#the-reusable-workflow-redbubble-only)), so a required check doesn't block it. So the pass
isn't mistaken for a review, the skip also posts one comment on the PR saying why. Later skips
update that comment rather than adding another, and it stays after a review runs, as a record of
the skip. A skipped draft gets no comment: it's reviewed once it's marked ready.

Pull requests Dependabot opens aren't reviewed either, unless the repository sets
`review-dependabot` (see [Reviewing Dependabot pull requests](docs/dependabot.md))
or someone adds the review label. They also pass the check, with no comment.

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

## How it works

On every pull request it reviews, the action:

1. **Creates read-only tokens** from the review GitHub App, one for each organisation, and passes
   them to Claude as `RB_READ_TOKEN` (redbubble) and `TP_READ_TOKEN` (teepublic). It also
   exchanges the Atlassian service account's OAuth credential at `auth.atlassian.com` for an
   access token that lasts an hour, passed as `ATLASSIAN_READ_TOKEN` (see
   [Why `atlassian-read`](docs/security.md#why-atlassian-read)).
2. **Checks out the rules** from redbubble/claude-code-reviews-rules, at `master` or the
   [pinned](docs/configuration.md#pinning-the-rules) commit, into `.claude-code-reviews/` with the redbubble token. If
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

## Documentation

| Page | What's in it |
| --- | --- |
| [Configuring the workflow](docs/configuration.md) | Reviewing only when asked, pinning the logic or the rules, the model, the findings limit, resolving earlier findings, and the reusable workflow for redbubble repositories. |
| [Dependabot pull requests](docs/dependabot.md) | Why they're skipped by default, and how to review them. |
| [Metrics in Datadog](docs/metrics.md) | What each run sends to Datadog, and how it's tagged. |
| [Local reviews](docs/local-reviews.md) | Reviewing your branch on your machine before opening a pull request. |
| [Security notes](docs/security.md) | What the review can and can't do, and why each helper refuses what it does. |
| [CI Bootstrapping](docs/bootstrapping.md) | The one-time setup: the GitHub App, organisation secrets and the Atlassian service account. |
| [Contributing](CONTRIBUTING.md) | The repository's layout, and what to check when changing the action. |
