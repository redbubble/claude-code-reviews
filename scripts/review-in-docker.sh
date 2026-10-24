#!/bin/bash
# Runs inside the review container (see docker-compose.yml): reviews the repository in the working
# directory against the rules in /opt/claude-code-reviews/rules/, and prints the review.
set -euo pipefail

rules=/opt/claude-code-reviews/rules

# Locally, gh-read uses the engineer's own token for both organisations. gh-read refuses
# anything but reads, since this token can usually write.
export RB_READ_TOKEN="${GH_TOKEN:-}" TP_READ_TOKEN="${GH_TOKEN:-}"
export PATH="/opt/claude-code-reviews/bin:/opt/claude-code-reviews/helpers:$PATH"

base="${REVIEW_BASE:-}"
if [ -z "$base" ]; then
  # No origin/HEAD is normal in a clone made without it: fall back to the usual names.
  base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null || true)
  for candidate in origin/main origin/master main master; do
    [ -n "$base" ] && break
    git rev-parse --verify --quiet "$candidate^{commit}" > /dev/null && base="$candidate"
  done
fi
if [ -z "$base" ]; then
  echo "run-local.sh: can't find the base branch; pass it, e.g. scripts/run-local.sh origin/main" >&2
  exit 2
fi
merge_base=$(git merge-base HEAD "$base")
branch=$(git branch --show-current)

echo "Reviewing ${REVIEW_REPO:-this repository} (${branch:-detached HEAD}) against $base ($(git rev-parse --short "$merge_base"))" >&2
echo "Rules: ${RULES_VERSION:-unknown} · model: $CLAUDE_MODEL · this takes a few minutes" >&2
echo >&2

prompt="REPO: ${REVIEW_REPO:-unknown}
BRANCH: ${branch:-detached HEAD}
BASE: $base (merge base $merge_base)

You are a code review specialist, reviewing an engineer's local changes in an Articore
repository before they open a pull request.

Before anything else, load the Articore review rules from \`$rules/\`: read \`RULES.md\` first,
then the other rule files in that folder, in the order \`RULES.md\` gives. Follow them exactly,
with these changes for a local review:

- The change under review is \`git diff $merge_base\`: the branch's commits plus uncommitted
  changes. Untracked files (\`git ls-files --others --exclude-standard\`) count as added files:
  read them in full.
- There may be no pull request yet. For the title and description in \"Before reviewing\", use
  the branch's commit messages (\`git log $merge_base..HEAD\`), plus the title and description
  of an open pull request for this branch if \`gh pr view\` finds one. Skip the earlier review
  threads, hiding summaries and setting labels: they're for pull requests.
- Post nothing. Print the review: each finding as its severity marker, then \`path:line\`, then
  the comment as it would be posted (suggestions as plain code blocks). Then the review
  summary, as \`POST-REVIEW.md\` describes, without the sections about earlier runs, and with
  \"Rules applied:\" naming ${RULES_VERSION:-the rules version}.
- Other repositories: read them with \`gh-read\` as the rules say. If it fails, list what you
  couldn't read under \"Not assessed\". The same goes for Jira and Confluence with
  \`atlassian-read\`."

exec claude -p "$prompt" \
  --model "$CLAUDE_MODEL" \
  --add-dir /opt/claude-code-reviews \
  --allowedTools 'Read,Glob,Grep,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git ls-files:*),Bash(git merge-base:*),Bash(git rev-parse:*),Bash(gh pr view:*),Bash(gh issue view:*),Bash(gh-read:*),Bash(atlassian-read:*)'
