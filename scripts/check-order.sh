#!/usr/bin/env bash
set -euo pipefail

# Lab copy of chi's check-migration-ordering.sh, pointed at migrations/.
# Fails if any migration added on this branch (vs origin/main) is not STRICTLY
# greater than every timestamp already on origin/main, OR if the added set
# contains a duplicate timestamp. Runs on pull_request AND merge_group (E2 proved
# origin/main...HEAD resolves in the merge_group checkout when fetch-depth: 0).
#
# The `<=` rule (not just `<`) and the duplicate scan are the E5 defense in depth:
# two concurrent healers used to be able to rebump two PRs to the SAME slot, and a
# strict-< check let the tie through, landing a duplicate timestamp on main. Now a
# tie with main's max, or a duplicate within the merged set, fails the gate.

cd "$(git rev-parse --show-toplevel)"

migration_ts() { basename "$1" | grep -oE '^[0-9]{14}' || true; }

main_max=$(git ls-tree -r --name-only origin/main -- migrations/ 2>/dev/null \
  | grep -E '^migrations/[0-9]{14}_.*\.sql$' \
  | sed -E 's|.*/([0-9]{14})_.*|\1|' | sort | tail -n1 || true)

[ -z "$main_max" ] && { echo "no migrations on origin/main — nothing to check"; exit 0; }

branch_added=$(git diff --diff-filter=AR -M --name-only origin/main...HEAD -- 'migrations/*.sql' 2>/dev/null \
  | grep -E '^migrations/[0-9]{14}_.*\.sql$' || true)

[ -z "$branch_added" ] && { echo "no new migrations on this branch"; exit 0; }

out_of_order=""
added_ts=""
while IFS= read -r f; do
  ts=$(migration_ts "$f")
  [ -z "$ts" ] && continue
  added_ts="${added_ts}${ts}"$'\n'
  if [ "$ts" \< "$main_max" ] || [ "$ts" = "$main_max" ]; then
    out_of_order="${out_of_order}  ${f} (${ts} <= ${main_max})"$'\n'
  fi
done <<< "$branch_added"

dups=$(printf '%s' "$added_ts" | grep -v '^$' | sort | uniq -d || true)

status=0
if [ -n "$out_of_order" ]; then
  echo "ERROR: migrations not strictly past latest on origin/main (${main_max}):"
  printf '%s' "$out_of_order"
  status=1
fi
if [ -n "$dups" ]; then
  echo "ERROR: duplicate migration timestamp(s) in the merged set:"
  printf '  %s\n' $dups
  status=1
fi

[ "$status" -ne 0 ] && exit 1
echo "Migration ordering OK (latest on main: ${main_max})"
