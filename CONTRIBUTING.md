# Contributing

## Repository layout

| Path | Purpose |
| --- | --- |
| `action.yml` | The action: decides whether to review, gets the tokens, checks out the rules and runs Claude. |
| `.github/workflows/review.yml` | An optional reusable workflow for redbubble repositories: the job that runs the action, with its runner, timeout, concurrency and secrets. |
| `bin/gh` | Wraps `gh` on Claude's PATH: keeps `gh pr` and `gh issue` to the repository under review, and `--jq` away from the environment. |
| `bin/gh-read` | `gh api` for other repositories, with the right organisation's read-only token, and for public repositories anywhere on GitHub. |
| `bin/atlassian-read` | Reads one Jira issue or Confluence page, as text, with the review's read-only Atlassian token. |
| `bin/gh-review-threads` | Lists the PR's review threads, and resolves or replies to Claude's own. Hides Claude's earlier summaries and sets the PR's `claude-review:*` labels. |
| `Dockerfile`, `docker-compose.yml` | The container local reviews run in: tools only. |
| `scripts/run-local.sh` | Runs a local review of the repository you're in. |
| `scripts/review-in-docker.sh` | Runs inside the container: starts Claude on the review. |
| `scripts/test-wrappers.sh` | Tests what `bin/gh`, `bin/gh-read`, `bin/gh-review-threads` and `scripts/git-in-docker.sh` refuse and allow, with a stub `gh`. |
| `scripts/git-in-docker.sh` | `git` inside the container: refuses `--output`, `--no-index` and paths outside the repository, so git can't write files or read others. |

## Changing the action

- Changes go through a pull request, approved by a code owner. This repository isn't reviewed by
  the action in CI: it's public, the organisation secrets are only available to private
  repositories, and the action refuses to run in a public one (see
  [Security notes](docs/security.md)). To have Claude review a change, run a
  [local review](docs/local-reviews.md) on its branch.
- Keep the defaults of `review.yml`'s inputs the same as `action.yml`'s: the workflow always
  passes them, so its defaults are the ones that apply.
- Keep the action working with every rules version a repository may have pinned. Add helpers and
  inputs; don't remove or change them under rules that use them.
- Claude can only run a new helper in `bin/` once it's in `--allowedTools` in `action.yml`. Check
  it for a way to write files first (see [Security notes](docs/security.md)).
- After changing `bin/gh`, `bin/gh-read`, `bin/gh-review-threads` or
  `scripts/git-in-docker.sh`, run `scripts/test-wrappers.sh`, and add a case for anything new
  they refuse.
- Changes to the rules go to redbubble/claude-code-reviews-rules, and so do decisions about
  either repository, as ADRs.
