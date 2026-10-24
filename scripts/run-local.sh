#!/bin/bash
# Reviews the repository you're in against the Articore review rules, in a container, before you
# open a pull request. Prints the review; changes nothing.
#
# Usage: run-local.sh [--rebuild] [--set-token] [base-ref]   (default base: origin's default branch)
#   --rebuild    rebuild the image first, e.g. after changing the Dockerfile
#   --set-token  paste a token you already have from `claude setup-token`, and store it
#
# Needs Docker. Uses ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN from the environment if set;
# otherwise a Claude Code token it stored on an earlier run, or it runs `claude setup-token` and
# stores the token (macOS Keychain, or ~/.config/claude-code-reviews/oauth-token elsewhere).
# Uses `gh auth token` to read pull requests and other repositories, if gh is logged in.
# Reads Jira issues and Confluence pages with ATLASSIAN_READ_TOKEN (and ATLASSIAN_EMAIL), if set.
# Reviews with the model in CLAUDE_REVIEW_MODEL, if set, else the same default as CI.
# Takes the rules from your clone of redbubble/claude-code-reviews-rules, whatever branch it's on:
# CLAUDE_REVIEW_RULES if set, else claude-code-reviews-rules next to this repository's clone.
set -euo pipefail

here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
compose=(docker compose -f "$here/../docker-compose.yml")
keychain_service=claude-code-reviews
token_file="$HOME/.config/claude-code-reviews/oauth-token"

warn() { echo "run-local.sh: $*" >&2; }
die() {
  warn "$@"
  exit 2
}

# The HTTP status Anthropic's API gives the credential in header $1: 200 valid, 401 invalid, 000
# unreachable. The header is passed through a file descriptor, so it isn't in the process list.
api_status() {
  # curl prints 000 and fails when it can't connect; the caller handles 000.
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://api.anthropic.com/v1/models \
    -H @<(printf '%s\n' "$1") -H 'anthropic-version: 2023-06-01' \
    -H 'anthropic-beta: oauth-2025-04-20' || true
}

# The token from an earlier run, or nothing (a missing entry isn't an error).
stored_token() {
  if command -v security > /dev/null; then
    security find-generic-password -s "$keychain_service" -a "$USER" -w 2> /dev/null || true
  elif [ -f "$token_file" ]; then
    cat "$token_file"
  fi
}

store_token() {
  if command -v security > /dev/null; then
    security add-generic-password -U -s "$keychain_service" -a "$USER" -w "$1"
  else
    mkdir -p "$(dirname "$token_file")"
    (umask 077 && printf '%s\n' "$1" > "$token_file")
  fi
}

# Asks for a token from `claude setup-token`, checks it looks like one and stores it.
ask_token() {
  [ -t 0 ] || die "no Anthropic credential: set ANTHROPIC_API_KEY, or run this in a terminal to set up a token"
  # Claude Code's screen can leave the terminal's bracketed paste on, which wraps a paste in
  # ESC[200~ and ESC[201~: turn it off, and strip those and any whitespace from what's pasted.
  printf '\033[?2004l' >&2
  local token
  warn "paste the token Claude Code printed, starting with sk-ant-oat01- (not the code from the login page)"
  read -rsp "Token: " token
  echo >&2
  token=${token//$'\033[200~'/}
  token=${token//$'\033[201~'/}
  token=$(printf '%s' "$token" | tr -d '[:space:]')
  case "$token" in
    sk-ant-*) ;;
    '') die "nothing was pasted. Run \`$0 --set-token\` to paste the token again" ;;
    *) die "that isn't a token: it starts with $(printf '%q' "${token:0:8}"), not sk-ant-. The code from the login page goes into setup-token; the token is what it prints after. Run \`$0 --set-token\` to paste it again" ;;
  esac
  CLAUDE_CODE_OAUTH_TOKEN=$token
  store_token "$CLAUDE_CODE_OAUTH_TOKEN"
  warn "token stored: later runs use it without asking"
}

# The token in a recording of `claude setup-token`'s screen, or nothing. Removes terminal escape
# codes and carriage returns, then joins the token back up where the screen wrapped it: it's the
# last one to start before "Store this token", since the screen may draw part of it first.
# Anything else finds nothing, so the caller asks for the token: a guess could store part of it.
extract_token() {
  perl -0777 -ne '
    s/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\e\][^\a\e]*(?:\a|\e\\)//g; s/\e[()=>][0-9A-Za-z]?//g; s/\r//g;
    my @found = /(sk-ant-oat\d+-(?:(?!sk-ant-oat)[A-Za-z0-9_\-\s])+?)\s*Store this token/g;
    if (@found) { (my $t = $found[-1]) =~ s/\s//g; print $t }' "$1"
}

# Creates a token with `claude setup-token` and stores it. Records its screen to take the token
# from it, and asks you to paste it only if that fails. With Claude Code on the host it opens
# your browser. Without it, it runs in the review container, which can't open one: open the link
# it prints yourself.
setup_token() {
  [ -t 0 ] || die "no Anthropic credential: set ANTHROPIC_API_KEY, or run this in a terminal to set up a token"
  warn "creating a Claude Code token for local reviews (needs a Claude subscription)"
  local recording token
  recording=$(mktemp -d)
  # The recording holds the token: remove it however this ends.
  trap 'rm -rf "$recording"' EXIT
  if command -v claude > /dev/null; then
    warn "log in in the browser window it opens, and paste the code you get back into it"
    if [ "$(uname)" = Darwin ]; then
      script -q "$recording/screen" claude setup-token
    else
      script -q -c "claude setup-token" "$recording/screen"
    fi
  else
    warn "Claude Code isn't installed here, so this runs in the container and can't open your browser:"
    warn "open the link it prints, log in, and paste the code you get back into it"
    # The container's user has to write the recording. Docker Desktop for Mac lets it. Elsewhere,
    # it runs as another user: let it write one file it can't read back, in a folder no one else
    # can list or add to (script opens its file write-only).
    if [ "$(uname)" != Darwin ]; then
      chmod 711 "$recording"
      : > "$recording/screen"
      chmod 622 "$recording/screen"
    fi
    "${compose[@]}" run --rm -v "$recording:/out" --entrypoint script review \
      -q -c "claude setup-token" /out/screen
  fi
  printf '\033[?2004l' >&2
  # No perl, no recording or no token in it: each falls back to asking for the token below.
  token=$(extract_token "$recording/screen" 2> /dev/null || true)
  rm -rf "$recording"
  trap - EXIT
  if [ "${#token}" -ge 40 ]; then
    CLAUDE_CODE_OAUTH_TOKEN=$token
    store_token "$CLAUDE_CODE_OAUTH_TOKEN"
    warn "token stored: later runs use it without asking"
  else
    warn "couldn't read the token from setup-token's screen"
    ask_token
  fi
}

rebuild=no
set_token=no
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) rebuild=yes ;;
    --set-token) set_token=yes ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
  shift
done

TARGET_REPO=$(git rev-parse --show-toplevel)
GIT_COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir)
# Empty, or /worktrees/<name> in a worktree: where its git directory is inside GIT_COMMON_DIR.
git_dir=$(git rev-parse --absolute-git-dir)
GIT_DIR_SUFFIX=${git_dir#"$GIT_COMMON_DIR"}

if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN=$(gh auth token 2> /dev/null) || {
    echo "run-local.sh: gh isn't logged in: the review can't read pull requests or other repositories" >&2
    GH_TOKEN=
  }
fi

if [ -z "${ATLASSIAN_READ_TOKEN:-}" ]; then
  warn "ATLASSIAN_READ_TOKEN isn't set: the review can't read Jira issues or Confluence pages (see the README)"
fi

# CLAUDE_REVIEW_MODEL if set, else the action's default, as in CI.
CLAUDE_MODEL=${CLAUDE_REVIEW_MODEL:-$(awk '/^  model:/ { m = 1 } m && /^    default:/ { print $2; exit }' "$here/../action.yml")}
[ -n "$CLAUDE_MODEL" ] || die "couldn't read the default model from action.yml"

# owner/name, from an ssh or https GitHub origin URL. Without one, the review can't name the
# repository or find its pull request, but still runs. A missing origin is reported below.
origin=$(git remote get-url origin 2> /dev/null || true)
case "$origin" in
  *github.com[:/]*) REVIEW_REPO=$(printf '%s\n' "$origin" | sed -E 's#^.*github\.com[:/]##; s#\.git$##') ;;
  *)
    warn "origin isn't a GitHub repository (${origin:-no origin remote}): the review won't know its name or pull request"
    REVIEW_REPO=
    ;;
esac

# The rules: in review/ up to v0.11, at the root of the rules repository after that.
rules_clone=${CLAUDE_REVIEW_RULES:-$here/../../claude-code-reviews-rules}
[ -d "$rules_clone" ] || die "no rules at $rules_clone: clone redbubble/claude-code-reviews-rules next to this repository, or set CLAUDE_REVIEW_RULES to your clone"
RULES_DIR=$(cd "$rules_clone" && pwd)
[ -f "$RULES_DIR/review/RULES.md" ] && RULES_DIR=$RULES_DIR/review
[ -f "$RULES_DIR/RULES.md" ] || die "no RULES.md in $rules_clone: is it a clone of redbubble/claude-code-reviews-rules?"
rules_title=$(head -1 "$RULES_DIR/RULES.md")
rules_commit=$(git -C "$RULES_DIR" describe --always --dirty)
rules_branch=$(git -C "$RULES_DIR" branch --show-current)
RULES_VERSION="rules ${rules_title##*(} from claude-code-reviews-rules ${rules_branch:-detached} @ $rules_commit"
RULES_VERSION=${RULES_VERSION/)/}
if [ "$rules_branch" != master ]; then
  echo "run-local.sh: using the rules from claude-code-reviews-rules branch $rules_branch, not master" >&2
fi

export TARGET_REPO GIT_COMMON_DIR GIT_DIR_SUFFIX GH_TOKEN CLAUDE_MODEL REVIEW_REPO RULES_DIR RULES_VERSION
export REVIEW_BASE="${1:-}"
[ "$rebuild" = no ] || "${compose[@]}" build --pull

# Anthropic credential: an API key wins, then a token from the environment, then the stored one.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  [ "$set_token" = no ] || die "--set-token stores a Claude Code token, but ANTHROPIC_API_KEY is set and is used first: unset it to use a token"
  case $(api_status "x-api-key: $ANTHROPIC_API_KEY") in
    200) ;;
    401) die "Anthropic rejected ANTHROPIC_API_KEY: check or unset it" ;;
    *) warn "couldn't check ANTHROPIC_API_KEY with Anthropic: trying it anyway" ;;
  esac
else
  token_source=environment
  if [ "$set_token" = yes ]; then
    token_source=pasted
    ask_token
  elif [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    token_source=stored
    CLAUDE_CODE_OAUTH_TOKEN=$(stored_token)
  fi
  if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    setup_token
  else
    # Only a hint: a 401 from this endpoint for a valid token hasn't been ruled out.
    status=$(api_status "Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN")
    if [ "$status" = 401 ]; then
      warn "Anthropic rejected the $token_source Claude Code token: it may have expired, or not be a token"
      if [ "$token_source" = environment ]; then
        warn "it's CLAUDE_CODE_OAUTH_TOKEN in your environment: unset it to use the stored token instead"
      fi
      if [ -t 0 ]; then
        read -rp "Create a new one and store it? [y/N] " answer
        case "$answer" in [yY]*) setup_token ;; esac
      fi
    fi
  fi
  export CLAUDE_CODE_OAUTH_TOKEN
fi

exec "${compose[@]}" run --rm review
