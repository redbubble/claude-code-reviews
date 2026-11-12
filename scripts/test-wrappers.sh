#!/bin/bash
# Tests the wrappers that keep the review's commands in bounds: bin/gh, bin/gh-read,
# bin/gh-review-threads and scripts/git-in-docker.sh. Run it after changing any of them; it needs
# no network, token or Docker.
#
# A stub gh stands in for the real one: it prints the arguments it was given, and says any
# repository is public when gh-read asks. So these tests check what each wrapper refuses and what it
# passes on, not what GitHub returns.
# shellcheck disable=SC2016 # $ENV in the jq programs below is meant literally, not expanded
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/stub"
cat > "$tmp/stub/gh" << 'EOF'
#!/bin/sh
if [ "$1" = api ] && [ "$3" = --jq ] && [ "$4" = .visibility ]; then
  echo public
  exit 0
fi
# gh-review-threads' thread lookup: the thread's "<repo>#<pr> <first author> <first comment>".
case "$*" in
  *PullRequestReviewThread*)
    echo "$STUB_THREAD"
    exit 0
    ;;
esac
echo "gh GH_HOST=${GH_HOST:-} :: $*"
EOF
chmod +x "$tmp/stub/gh"

passed=0
failed=0
allows() {
  local out
  if out=$("$@" 2>&1); then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL, should allow: $* -> $out"
  fi
}
refuses() {
  local out
  if out=$("$@" 2>&1); then
    failed=$((failed + 1))
    echo "FAIL, should refuse: $* -> $out"
  else
    passed=$((passed + 1))
  fi
}

(
  export PATH="$repo/bin:$tmp/stub:/usr/bin:/bin" RB_READ_TOKEN=rb TP_READ_TOKEN=tp

  # bin/gh: other commands pass through untouched, whatever their arguments.
  allows gh api graphql -f body="- the env var is wrong"
  allows gh api "repos/redbubble/x/issues/1/comments" --jq '.[].id'

  # bin/gh: gh pr and gh issue in the repository under review.
  allows gh pr view 12 --json title,body
  allows gh pr view my/feature-branch
  allows gh pr diff 12
  allows gh pr list --search "is:open fix" --json number
  allows gh pr view 12 --json commits --jq '.commits[].messageHeadline'
  allows gh pr view 12 --json files --jq '.files[] | select(.path | test("environment"))'
  allows gh issue view 3 --comments
  if [ "$(gh pr view 1)" = "gh GH_HOST=github.com :: pr view 1" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: gh pr doesn't force GH_HOST=github.com"
  fi

  # bin/gh: another repository or host.
  refuses gh pr view 1 -R other/private
  refuses gh pr view 1 --repo other/private
  refuses gh pr view 1 --repo=evil.example.com/o/r
  refuses gh pr view 1 -Rother/private
  refuses gh pr view 1 -cR other/private
  refuses gh pr -R other/private view 1
  refuses gh pr view https://evil.example.com/o/r/pull/1
  refuses gh pr view https://github.com/someone/private/pull/1
  refuses gh issue view other/repo#5
  refuses gh pr view 1 --hostname evil.example.com
  refuses gh pr list --search "repo:other/private"
  refuses gh pr list -S "org:someone"
  refuses gh pr list --search="user:x fix"
  refuses gh pr list --head -S -S "repo:other/private"

  # bin/gh: a --jq program that reads the environment, including after a flag that takes the next
  # argument as its value (gh reads --head --jq --jq env as --head "--jq" and --jq env).
  refuses gh pr view 1 --json title --jq '$ENV.ANTHROPIC_API_KEY'
  refuses gh pr view 1 --json title -q 'env'
  refuses gh pr view 1 --json title --jq='env.GH_TOKEN'
  refuses gh pr view 1 --json title -q'$ENV'
  refuses gh pr list --json number --head --jq --jq env
  refuses gh pr list --json number --head -q -q '$ENV.GH_TOKEN'

  # gh-read: the reads the rules use.
  allows gh-read "repos/redbubble/x/contents/a?ref=abc" -H "Accept: application/vnd.github.raw"
  allows gh-read repos/redbubble/x/pulls/2 -H 'Accept: application/vnd.github.diff'
  allows gh-read repos/cli/cli/releases/tags/v2.0.0 --jq .body
  allows gh-read repos/cli/cli/contents/CHANGELOG.md -H 'Accept: application/vnd.github.raw+json'
  allows gh-read repos/cli/cli/releases --paginate
  allows gh-read repos/redbubble/x/releases/assets/1

  # gh-read: release-asset downloads outside the two organisations, in any spelling.
  refuses gh-read repos/attacker/x/releases/assets/123
  refuses gh-read repos/attacker/x/Releases/Assets/123
  refuses gh-read repos/attacker/x//releases//assets/123
  refuses gh-read "/repos/attacker/x/releases/assets?x=1"
  refuses gh-read repos/attacker/x/releases/assets

  # gh-read: headers other than a GitHub Accept, the environment, and writes.
  refuses gh-read repos/redbubble/x/contents/a -H 'Accept: application/octet-stream'
  refuses gh-read repos/cli/cli -H 'X-Foo: bar'
  refuses gh-read repos/cli/cli --header='Accept: application/octet-stream'
  refuses gh-read repos/redbubble/x --jq '$ENV.ANTHROPIC_API_KEY'
  refuses gh-read repos/redbubble/x --jq=env
  refuses gh-read repos/redbubble/x -q '[env[]]'
  refuses gh-read repos/redbubble/x -t --jq env
  refuses gh-read repos/redbubble/x -X POST

  # gh-review-threads: only the pull request in REVIEW_PR, whatever number Claude gives.
  export GITHUB_REPOSITORY=redbubble/x REVIEW_PR=12
  allows gh-review-threads list 12
  allows gh-review-threads hide-summaries 12
  allows gh-review-threads labels 12 important
  refuses gh-review-threads list 13
  refuses gh-review-threads hide-summaries 13
  refuses gh-review-threads labels 13 important
  refuses gh-review-threads labels 012 important
  STUB_THREAD="redbubble/x#12 github-actions C1" allows gh-review-threads reply T1 "Fixed, thanks"
  STUB_THREAD="redbubble/x#12 claude C1" allows gh-review-threads resolve T1
  STUB_THREAD="redbubble/x#13 github-actions C1" refuses gh-review-threads reply T1 "Fixed"
  STUB_THREAD="redbubble/x#13 github-actions C1" refuses gh-review-threads resolve T1
  STUB_THREAD="redbubble/other#12 github-actions C1" refuses gh-review-threads resolve T1
  STUB_THREAD="redbubble/x#12 someone C1" refuses gh-review-threads resolve T1
  REVIEW_PR='' refuses gh-review-threads list 12
  REVIEW_PR=12abc refuses gh-review-threads list 12
  unset GITHUB_REPOSITORY REVIEW_PR

  # git-in-docker.sh, as `git`, in a scratch repository.
  mkdir "$tmp/git" "$tmp/work"
  ln -s "$here/git-in-docker.sh" "$tmp/git/git"
  cd "$tmp/work" || exit 1
  /usr/bin/git init -q
  echo hi > README.md
  /usr/bin/git add README.md
  /usr/bin/git -c user.email=test@example.com -c user.name=test commit -qm one
  echo there >> README.md
  export PATH="$tmp/git:$PATH" GIT_CONFIG_GLOBAL=/dev/null
  allows git log --oneline -1
  allows git diff --stat
  allows git diff HEAD -- README.md
  allows git show HEAD:README.md
  allows git log -1 --format=%H HEAD
  refuses git diff --no-index /proc/self/environ /dev/null
  refuses git diff --no-i a b
  refuses git diff /etc/passwd README.md
  refuses git diff ../etc/passwd README.md
  refuses git diff /workspace/../proc/self/environ README.md
  refuses git diff --output=out.txt
  refuses git log --out=out.txt

  echo "passed $passed, failed $failed"
  [ "$failed" -eq 0 ]
)
