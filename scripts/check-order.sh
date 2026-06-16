#!/usr/bin/env bash
set -euo pipefail

# Lab copy of chi's check-migration-ordering.sh, pointed at migrations/.
# Fails if any migration added on this branch (vs origin/main) has a 14-digit
# timestamp earlier than the greatest timestamp already on origin/main.
# Runs on pull_request AND merge_group (E2 proved origin/main...HEAD resolves
# in the merge_group checkout when fetch-depth: 0).

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
while IFS= read -r f; do
  ts=$(migration_ts "$f")
  if [ -n "$ts" ] && [ "$ts" \< "$main_max" ]; then
    out_of_order="${out_of_order}  ${f} (${ts} < ${main_max})"$'\n'
  fi
done <<< "$branch_added"

if [ -n "$out_of_order" ]; then
  echo "ERROR: migrations earlier than latest on origin/main (${main_max}):"
  printf '%s' "$out_of_order"
  exit 1
fi

echo "Migration ordering OK (latest on main: ${main_max})"
