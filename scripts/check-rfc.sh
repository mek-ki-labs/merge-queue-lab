#!/usr/bin/env bash
set -euo pipefail

# Lab copy of chi's check-rfc-collisions.sh. Fails if an RFC ADDED on this branch
# (vs origin/main) reuses a 4-digit number that already exists on origin/main, or
# if the branch's added set contains a duplicate number. Runs on pull_request AND
# merge_group — the merge_group run is the authoritative one: two PRs that each
# grabbed the next-free number at authoring time both pass their own PR check, then
# the loser collides with origin/main once the winner merges, and is ejected here.
#
# This is the RFC analogue of check-order.sh. The number IS the identity, so unlike
# migration timestamps we do not rebump on a mere tie with main's max — only on an
# actual reuse of a number already present on main (or a dup within the added set).

cd "$(git rev-parse --show-toplevel)"

rfc_num() { basename "$1" | grep -oE '^[0-9]{4}' || true; }

main_nums=$(git ls-tree -r --name-only origin/main -- docs/rfcs/ 2>/dev/null \
  | grep -E '^docs/rfcs/[0-9]{4}-.*\.md$' \
  | sed -E 's|.*/([0-9]{4})-.*|\1|' | sort -u || true)

branch_added=$(git diff --diff-filter=AR -M --name-only origin/main...HEAD -- 'docs/rfcs/*.md' 2>/dev/null \
  | grep -E '^docs/rfcs/[0-9]{4}-.*\.md$' || true)

[ -z "$branch_added" ] && { echo "no new RFCs on this branch"; exit 0; }

collisions=""
added_nums=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  n=$(rfc_num "$f")
  [ -z "$n" ] && continue
  added_nums="${added_nums}${n}"$'\n'
  if printf '%s\n' "$main_nums" | grep -qx "$n"; then
    collisions="${collisions}  ${f} (RFC ${n} already exists on origin/main)"$'\n'
  fi
done <<< "$branch_added"

dups=$(printf '%s' "$added_nums" | grep -v '^$' | sort | uniq -d || true)

status=0
if [ -n "$collisions" ]; then
  echo "ERROR: RFC number(s) collide with origin/main:"
  printf '%s' "$collisions"
  status=1
fi
if [ -n "$dups" ]; then
  echo "ERROR: duplicate RFC number(s) in the added set:"
  printf '  %s\n' $dups
  status=1
fi

[ "$status" -ne 0 ] && exit 1
echo "RFC numbering OK"
