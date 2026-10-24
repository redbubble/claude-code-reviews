# The environment for local reviews: tools only. The helpers and the script that runs the review
# are mounted from this repository at run time, and the rules from your clone of
# claude-code-reviews-rules (see docker-compose.yml), so editing them needs no rebuild.
FROM node:24.22.0-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.304

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git jq ripgrep \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force

# The repository under review is mounted read-only and owned by another user: let git read it, and
# don't let it try to refresh the index.
RUN git config --system safe.directory '*'
ENV GIT_OPTIONAL_LOCKS=0

USER node
