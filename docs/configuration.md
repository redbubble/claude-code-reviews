# Configuring the workflow

Each of these is a change to the workflow in [Usage](../README.md#usage), made through a pull request like any
other workflow change.

## Reviewing only when asked

To review a pull request only when someone asks for it, replace the `on:` block with a `labeled`
trigger, and skip every other label:

```yaml
on:
  pull_request:
    types: [labeled]

jobs:
  claude-review:
    if: github.event.label.name == 'claude-review'
    # ...the rest of the job as in the README's Usage
```

Add the `claude-review` label to a pull request to review it, draft or not. To review a later
push, remove the label and add it again. The `if:` matters: without it, adding any other label
starts a job that cancels a review in progress.

Don't make the `claude-review` check required with this workflow. GitHub counts a job its `if:`
skips as passed, so adding any other label to a pull request passes the check without a review.
A required check needs the default triggers in [Usage](../README.md#usage), where every push is reviewed.

## Pinning the logic

`@master` runs the latest action on every review. To choose when the action changes, use a full
40-character commit SHA from this repository's `master` instead:

```yaml
      - uses: redbubble/claude-code-reviews@0123456789abcdef0123456789abcdef01234567
```

We keep the action working with every rules version, so most repositories leave this on
`master` and pin the rules instead.

Either way, the actions this one uses are pinned to commit SHAs in `action.yml`, so a pinned
commit of this action always runs the same code. Pinning the
[reusable workflow](#the-reusable-workflow-redbubble-only) doesn't do this: it calls the action
at `master` whatever commit of it you use.

## Pinning the rules

The rules follow `master` of redbubble/claude-code-reviews-rules by default, so a rule change
applies everywhere on the next review. To choose when your repository takes new rules, pin a
commit with `rules-ref`:

```yaml
        with:
          # ...the inputs as in the README's Usage
          rules-ref: 0123456789abcdef0123456789abcdef01234567  # review baseline v0.11
```

Use the merge commit on `master` of the baseline version you want: the version is in the title of
`RULES.md` and in the commit message. Use the full 40-character SHA: a short one won't check out.
Say which version it is in a comment.

To update, change the SHA in a pull request. The review on that pull request uses the new rules,
so you see how they behave on your code before merging. To go back to following every change,
remove `rules-ref`. A pinned repository gets no rule changes until it updates, fixes included,
and nothing tells it a newer version exists.

## Choosing the model

The review uses `claude-opus-5-5`. To use another model, add `model` with a model ID:

```yaml
        with:
          # ...the inputs as in the README's Usage
          model: claude-sonnet-5-5
```

The value is pasted into `claude_args`, which the action splits into separate flags, so the
review fails unless it's a single model ID with no spaces or quotes. Otherwise it could add flags
such as a wider `--allowedTools`. A model ID that doesn't exist also fails the review rather than
falling back to the default.

## Choosing the effort

By default the review runs at the Claude Code CLI's default effort. To change it, add `effort`
with `low`, `medium`, `high`, `xhigh` or `max`:

```yaml
        with:
          # ...the inputs as in the README's Usage
          effort: high
```

Any other value fails the review. A repository can pick the effort per pull request, for example
a second label that asks for `high`, by setting `effort` from the label in its workflow:

```yaml
    if: contains(fromJSON('["claude-review", "claude-review-deep"]'), github.event.label.name)
    # ...
        with:
          effort: ${{ github.event.label.name == 'claude-review-deep' && 'high' || '' }}
```

A higher effort costs more per review: check the cost line at the end of the review comment.

## Limiting the findings

A review posts at most 5 new findings, of every severity together. Important findings come
first and are always posted, even past the limit; the rest fill what's left, most impactful
first. The summary says how many were left out. To set your own limit, add `max-findings`:

```yaml
        with:
          # ...the inputs as in the README's Usage
          max-findings: 8
```

It must be a number from 1 to 999, and it's a hard limit: Important findings still come first,
but no more than that are posted, even when that leaves some Important ones out. Rules versions
up to v0.14 ignore it and cap Nits at 5 instead. For local reviews, set
`CLAUDE_REVIEW_MAX_FINDINGS`.

## Resolving or minimising earlier findings

When a later push fixes an issue the review raised, the review closes its thread. How it closes it
depends on one permission in the workflow, and each repository chooses:

| | `contents: read` (the default in the README's Usage) | `contents: write` |
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

## The reusable workflow (redbubble only)

The workflow in [Usage](../README.md#usage) is what we recommend everywhere. A repository in the **redbubble**
organisation can instead call [`review.yml`](../.github/workflows/review.yml), a reusable workflow
that holds the job: its runner, timeout, concurrency and which secrets the review uses. A change
to any of those, like adding a new secret, then reaches the repository without a pull request
there. The job in your workflow becomes:

```yaml
jobs:
  claude-review:
    uses: redbubble/claude-code-reviews/.github/workflows/review.yml@master
    secrets: inherit
    with:                   # optional: the inputs on this page, or `review-dependabot`
      model: claude-sonnet-5-5
```

Keep your `on:` and `permissions:` blocks: the permissions are the most the job's token gets.
The label trigger in [Reviewing only when asked](#reviewing-only-when-asked) works the same way,
with its `if:` next to `uses:`.

Before you switch:

- **It's for redbubble repositories.** GitHub only passes secrets with `secrets: inherit` to a
  reusable workflow in the same organisation, or the same enterprise, which we don't have. A
  teepublic repository can still call it by listing each secret under `secrets:`, but then a new
  secret needs a pull request there anyway, and it gains little over the step. We recommend the
  step so a repository is set up the same way whichever organisation it's in: see
  redbubble/claude-code-reviews-rules' decision record on this.
- **`secrets: inherit` passes every secret the repository can read**, not only the review's.
  `review.yml` hands the action only the ones it uses, but a change to `review.yml` on `master`
  could read the rest. To pass only the review's, list them instead:

  ```yaml
      secrets:
        ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        REVIEW_APP_PRIVATE_KEY: ${{ secrets.REVIEW_APP_PRIVATE_KEY }}
        ATLASSIAN_CLIENT_SECRET: ${{ secrets.ATLASSIAN_CLIENT_SECRET }}
        DATADOG_API_KEY: ${{ secrets.DATADOG_API_KEY }}
  ```

- **The check is named `claude-review / review`**: your job, then the job in `review.yml`. If
  `claude-review` is a required check, rename it in the branch protection rule or ruleset in the
  same change, or pull requests wait for a check that never reports.
- **It can't be pinned.** `review.yml@<SHA>` fixes the job, but it calls the action at `master`.
  To [pin the logic](#pinning-the-logic), call the action as a step.
