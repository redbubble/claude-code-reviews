#!/bin/sh
# Mounted as `git`, first on the review container's PATH (see docker-compose.yml), so the git
# commands Claude may run (diff, log, show...) can't write files. `--output=<path>` would let it
# write anywhere it can, such as a git config whose core.fsmonitor the next git command runs, with
# the engineer's tokens in its environment.
set -eu
refused=--output
for arg in "$@"; do
  name="${arg%%=*}"
  # --output, and any abbreviation of it a git version might accept: a name that $refused starts
  # with.
  case "$name" in
    --o*)
      if [ "${refused#"$name"}" != "$refused" ]; then
        echo "git: $arg isn't allowed in a review: it writes a file" >&2
        exit 2
      fi
      ;;
  esac
done
exec /usr/bin/git "$@"
