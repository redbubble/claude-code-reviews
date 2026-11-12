#!/bin/sh
# Mounted as `git`, first on the review container's PATH (see docker-compose.yml), so the git
# commands Claude may run (diff, log, show...) can't write files. `--output=<path>` would let it
# write anywhere it can, such as a git config whose core.fsmonitor the next git command runs, with
# the engineer's tokens in its environment.
#
# Nor can they read files outside the repository: `git diff` compares any two files when one is
# outside the work tree, or with --no-index, and /proc/self/environ holds the engineer's tokens.
set -eu
refuse() {
  echo "git: $*" >&2
  exit 2
}
# Whether $1 is --output or --no-index, or an abbreviation of one that a git version might accept:
# a name that the option starts with, long enough to tell it from other options.
abbreviates() {
  case "$1" in
    --o*) [ "${2#"$1"}" != "$2" ] ;;
    --no-i*) [ "${2#"$1"}" != "$2" ] ;;
    *) return 1 ;;
  esac
}
for arg in "$@"; do
  name="${arg%%=*}"
  abbreviates "$name" --output && refuse "$arg isn't allowed in a review: it writes a file"
  abbreviates "$name" --no-index && refuse "$arg isn't allowed in a review: it reads files outside the repository"
  case "$arg" in
    .. | ../* | */../* | */..) refuse "$arg isn't allowed in a review: it can point outside the repository" ;;
    /workspace | /workspace/*) ;;
    /*) refuse "$arg isn't allowed in a review: give paths inside the repository" ;;
  esac
done
exec /usr/bin/git "$@"
