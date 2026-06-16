#!/usr/bin/env bash
set -euo pipefail

# Heal an out-of-order migration by rebumping its timestamp past origin/main's
# max, as a PURE RENAME. Sets GITHUB_OUTPUT changed=true|false. Refuses (exit 1)
# if it would touch anything other than a migration rename — the trust guard.
# Invoked by the healer workflow after a merge-queue ejection (merged == false).

cd "$(git rev-parse --show-toplevel)"

migration_ts() { basename "$1" | grep -oE '^[0-9]{14}' || true; }

main_max=$(git ls-tree -r --name-only origin/main -- migrations/ 2>/dev/null \
  | grep -E '^migrations/[0-9]{14}_.*\.sql$' \
  | sed -E 's|.*/([0-9]{14})_.*|\1|' | sort | tail -n1 || true)

branch_added=$(git diff --diff-filter=AR -M --name-only origin/main...HEAD -- 'migrations/*.sql' 2>/dev/null \
  | grep -E '^migrations/[0-9]{14}_.*\.sql$' || true)

changed=false
next=$((10#$main_max))
while IFS= read -r f; do
  [ -z "$f" ] && continue
  ts=$(migration_ts "$f")
  if [ -n "$ts" ] && [ "$ts" \< "$main_max" ]; then
    next=$((next + 1))
    new=$(printf '%014d' "$next")
    suffix=$(basename "$f" | sed -E 's/^[0-9]{14}_//')
    git mv "$f" "migrations/${new}_${suffix}"
    echo "rebumped ${f} -> migrations/${new}_${suffix}"
    changed=true
  fi
done <<< "$branch_added"

if [ "$changed" = true ]; then
  # TRUST GUARD: every staged change must be a rename (R) of a migrations/*.sql
  # file — no content edits, no other paths. Refuse otherwise.
  while IFS=$'\t' read -r status path rest; do
    case "$status" in
      R*) echo "$path" | grep -qE '^migrations/[0-9]{14}_.*\.sql$' || { echo "trust guard: unexpected rename $path"; exit 1; } ;;
      "") : ;;
      *)  echo "trust guard: non-rename change ($status $path) — refusing"; exit 1 ;;
    esac
  done < <(git diff --cached -M --name-status)

  git -c user.name="mek-ki-labs-healer[bot]" \
      -c user.email="mek-ki-labs-healer[bot]@users.noreply.github.com" \
      commit -q -m "heal: rebump out-of-order migration(s) past origin/main"
fi

echo "changed=${changed}" >> "$GITHUB_OUTPUT"
