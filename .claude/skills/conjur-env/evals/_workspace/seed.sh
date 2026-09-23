#!/usr/bin/env bash

# Seeds an eval run's empty workspace with this repo's tracked files, so the run
# has bin/env, the schema, the examples and the docs to hand -- in both arms. The
# baseline is then "an agent with the repo but without the skill", which is the
# comparison worth making, rather than an agent with nothing at all.
#
# Everything under .claude/ is left out so the baseline cannot read the skill. The
# workspace is its own git repository so that it looks like a real clone, and so
# `git check-ignore` would answer correctly if a future run is granted Bash.
#
# Called from each case's scaffold script with that script's own path, because the
# harness runs a scaffold from inside the empty workspace.

set -euo pipefail

repo="$(git -C "$(dirname "$1")" rev-parse --show-toplevel)"

git -C "$repo" ls-files -z -- ':!.claude' \
  | (cd "$repo" && tar --null --files-from - --create --file -) \
  | tar --extract --file -

git init --quiet
git add --all
git -c user.name=eval -c user.email=eval@example.invalid \
  commit --quiet --message 'Seed the eval workspace'
