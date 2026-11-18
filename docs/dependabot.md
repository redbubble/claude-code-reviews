# Reviewing Dependabot pull requests

Pull requests Dependabot opens are skipped by default. Most only change a version and a lockfile:
the repository's tests say more about an update than a review can, and a long lockfile diff
still costs a full review. To review them, add `review-dependabot`:

```yaml
        with:
          # ...the inputs as in the README's Usage
          review-dependabot: true
```

Dependabot's runs only get the secrets added under *Secrets and variables → Dependabot*, not the
Actions secrets, so add the review's there too (see
[CI Bootstrapping](bootstrapping.md#3-add-the-secrets-to-both-organisations)). Without them, every Dependabot
review fails.

To review one Dependabot pull request without the input, add the `claude-review` label. For that,
the workflow in [Usage](../README.md#usage) also needs the `labeled` type, and an `if:` that lets through every
other event but only that label:

```yaml
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened, labeled]

jobs:
  claude-review:
    if: github.event.action != 'labeled' || github.event.label.name == 'claude-review'
    # ...the rest of the job as in the README's Usage
```

Without the `if:`, any label starts a review, including the ones Dependabot adds when it opens a
pull request, and those runs fail without Dependabot secrets. With only the `if:` from
[Reviewing only when asked](configuration.md#reviewing-only-when-asked), nothing else is reviewed. A run from the
label is started by whoever added it, so it gets the Actions secrets and needs none under
Dependabot. To review it again after a push, remove the label and add it again.

With this trigger, don't make `claude-review` a required check. Every label added starts a run,
and for any label but `claude-review` the `if:` skips the job, which GitHub counts as passed. That
run is then the commit's latest `claude-review` check, so adding any label while a review is
running, or after one failed, passes the check without a review. A repository that requires the
check should set `review-dependabot: true` instead, with the secrets under *Dependabot*.

A Dependabot pull request that someone else has pushed to is reviewed as usual: the skip only
applies while every commit is Dependabot's own, signed by GitHub.

Either way, fewer, larger Dependabot pull requests cost less to review and to test. Group them in
the repository's `.github/dependabot.yml`, for example every minor and patch update in one
weekly pull request:

```yaml
version: 2
updates:
  - package-ecosystem: bundler   # or npm, pip, github-actions, ...
    directory: /
    schedule:
      interval: weekly
    groups:
      minor-and-patch:
        update-types: [minor, patch]
```
